defmodule Mojentic.LLM.RecoveryWireTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.{DecodingEvidence, ScriptedCompletionServer}
  alias Mojentic.Tracer.TracerSystem

  @env_keys [
    "OPENAI_API_ENDPOINT",
    "OPENAI_API_KEY",
    "OLLAMA_HOST",
    "OMLX_HOST",
    "OMLX_API_KEY",
    "OPENAI_TIMEOUT",
    "OLLAMA_TIMEOUT",
    "OMLX_TIMEOUT"
  ]
  setup do
    client = Application.fetch_env!(:mojentic, :http_client)
    saved = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)

      for {key, value} <- saved do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  @tag :metadata_echo_proof
  test "recognized provider code and UUID request ID echoes cannot enter public recovery metadata" do
    secret = "a539ba99-c7f8-4fd0-b324-d8b082925980"
    body = Jason.encode!(%{error: %{code: "overloaded"}})
    reply = String.replace(response(503, body), "wire-request-73", secret)
    server = start_supervised!({ScriptedCompletionServer, {self(), [reply]}})
    assert_receive {:server_port, port}
    configure(OpenAI, port)
    System.put_env("OPENAI_API_KEY", "overloaded")
    owner = self()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          admission: fn context ->
            send(owner, {:echo_admission, context})
            :reject
          end,
          observer: &send(owner, {:echo_event, &1})
        ]
      )

    assert {:error, error} = OpenAI.complete("gpt-4o", [Message.user(secret)], [], config)
    assert error.provider_code == nil
    assert error.provider_request_id == nil
    assert error.http_status == 503
    assert error.progress.headers_received
    assert error.progress.raw_bytes == byte_size(body)
    assert_receive {:wire_request, wire}
    assert wire =~ "Bearer overloaded"
    assert wire =~ secret
    assert GenServer.call(server, :requests) == [wire]
    assert_receive {:echo_admission, context}
    assert context.failure.provider_code == nil
    assert context.failure.provider_request_id == nil
    assert context.failure.attempt_id == error.attempt_id
    assert context.failure.logical_request_id == error.logical_request_id
    assert_receive {:echo_event, %{type: :attempt_started, metadata: started}}
    assert_receive {:echo_event, %{type: :attempt_failed, metadata: failed}}
    assert started.attempt_id == error.attempt_id
    assert failed.attempt_id == error.attempt_id
    assert failed.logical_request_id == error.logical_request_id
    assert [history] = error.history
    assert history == Map.delete(failed, :history)

    for safe <- [inspect(error), Jason.encode!(error), inspect(context), inspect(failed)] do
      refute safe =~ secret
      refute safe =~ "overloaded"
    end

    assert CompletionError.received_evidence(error).body == body
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :broker, :broker_object, :session],
      tracing <- [false, true],
      admitted <- [false, true],
      interruption <- [:closed, :timeout] do
    @gateway gateway
    @operation operation
    @tracing tracing
    @admitted admitted
    @interruption interruption
    @tag :ordinary_body_progress
    test "#{gateway} #{operation} incomplete 200 #{interruption} tracing #{tracing} admitted #{admitted} retains exact body evidence" do
      assert_body_progress(@gateway, @operation, @tracing, @admitted, @interruption)
    end
  end

  defp assert_body_progress(gateway, operation, tracing, admitted, interruption) do
    owner = self()
    object? = operation in [:complete_object, :broker_object]
    kind = if object?, do: :complete_object, else: :complete
    # A complete JSON value on an incomplete HTTP body must still fail.
    partial = String.replace(successful_body(gateway, kind), "done", "partial-body-secret-π")

    broken =
      String.replace(
        response(200, partial),
        "Content-Length: #{byte_size(partial)}",
        "Content-Length: 9999"
      )

    broken = if interruption == :timeout, do: {:stream_hold, broken}, else: broken

    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {owner, [broken, response(200, successful_body(gateway, kind))]}}
      )

    assert_receive {:server_port, port}
    configure(gateway, port)

    for key <- ["OPENAI_TIMEOUT", "OLLAMA_TIMEOUT", "OMLX_TIMEOUT"],
        do: System.put_env(key, "150")

    recovery = [
      max_attempts: 2,
      base_delay: 0,
      sleeper: fn _ -> :ok end,
      observer: &send(owner, {:body_lifecycle, &1})
    ]

    recovery =
      if admitted,
        do:
          Keyword.put(recovery, :admission, fn context ->
            send(owner, {:body_admission, context.failure})
            :allow
          end),
        else: recovery

    recovery =
      if tracing,
        do:
          Keyword.put(recovery, :trace_observer, fn event ->
            send(owner, {:body_trace, event})
            :ok
          end),
        else: recovery

    config = CompletionConfig.new(recovery: recovery)
    result = body_progress_invoke(gateway, operation, config)
    assert_receive {:body_lifecycle, %{type: :attempt_started, metadata: started}}
    assert_receive {:body_lifecycle, %{type: :attempt_failed, metadata: failed}}
    assert_body_failure(failed, started, partial, interruption)
    assert_receive {:wire_request, wire}

    expected_messages =
      if operation == :session do
        session = ChatSession.new(Broker.new("gpt-4o", gateway))

        Enum.map(session.messages, fn sized ->
          %{"role" => Atom.to_string(sized.message.role), "content" => sized.message.content}
        end) ++ [%{"role" => "user", "content" => "payload-secret"}]
      else
        [%{"role" => "user", "content" => "payload-secret"}]
      end

    assert_payload(wire, gateway, kind, expected_messages)

    assert_body_result(result, server, wire, failed, started, admitted, interruption)
    assert_body_trace(tracing, wire, started, partial, expected_messages)
  end

  defp assert_body_failure(failed, started, partial, interruption) do
    assert failed.http_status == 200
    assert failed.category == if(interruption == :timeout, do: :client_timeout, else: :transport)
    assert failed.reason == if(interruption == :timeout, do: :timeout, else: :transport_failure)
    assert failed.phase == :streaming
    assert failed.acceptance == :unknown
    assert failed.retry_eligible == (interruption == :closed)
    assert failed.provider_request_id == "wire-request-73"
    assert failed.retry_after == %{kind: :delay_seconds, value: 11}
    semantic = %{content: true, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

    assert failed.progress == %{
             headers_received: true,
             raw_bytes: byte_size(partial),
             observed: semantic,
             delivered: %{semantic | content: false}
           }

    assert UUID.info!(started.attempt_id)[:version] == 4
    assert UUID.info!(started.logical_request_id)[:version] == 4
    refute started.attempt_id == started.logical_request_id
    assert failed.attempt_id == started.attempt_id
    assert failed.logical_request_id == started.logical_request_id
    assert failed.wire_attempt == 1
    assert [history] = failed.history
    assert history == Map.delete(failed, :history)
  end

  defp assert_body_result(result, server, wire, failed, started, admitted, interruption) do
    if interruption == :closed and (admitted or failed.provider == :openai) do
      if admitted do
        assert_receive {:body_admission, failure}
        assert failure == failed
      else
        refute_received {:body_admission, _}
        assert_receive {:body_lifecycle, %{type: :admission_allowed, metadata: ^failed}}
      end

      assert_body_completion(result, failed.operation)

      assert_receive {:wire_request, retry}
      assert retry == wire
      assert GenServer.call(server, :requests) == [wire, retry]
      assert_receive {:body_lifecycle, %{type: :attempt_succeeded, metadata: succeeded}}
      assert succeeded.logical_request_id == started.logical_request_id
      refute succeeded.attempt_id == started.attempt_id
      assert succeeded.wire_attempt == 2
    else
      assert {:error, error} = result
      assert %Req.TransportError{reason: cause} = CompletionError.cause(error)
      assert cause == interruption
      assert error.category == failed.category
      assert error.reason == failed.reason

      assert error.resend_permission ==
               if(interruption == :timeout, do: :not_granted, else: :admission_required)

      assert error.progress == failed.progress
      assert error.http_status == 200
      assert [history] = error.history
      assert history == Map.delete(failed, :history)
      assert error.attempt_id == started.attempt_id
      assert error.logical_request_id == started.logical_request_id
      assert error.wire_attempt == 1
      refute inspect(error) =~ "partial-body-secret"
      refute Jason.encode!(error) =~ "partial-body-secret"
      refute inspect(failed) =~ "partial-body-secret"
      refute inspect(history) =~ "partial-body-secret"
      refute_received {:body_admission, _}
      refute_received {:body_lifecycle, %{type: :attempt_succeeded}}
      assert GenServer.call(server, :requests) == [wire]
    end
  end

  defp assert_body_completion(result, operation) do
    assert {:ok, completion} = result

    content =
      case completion do
        %Mojentic.LLM.GatewayResponse{object: object} when not is_nil(object) -> object
        %Mojentic.LLM.GatewayResponse{content: content} -> content
        content -> content
      end

    assert content ==
             if(operation == :complete_object, do: %{"value" => "done"}, else: "done")
  end

  defp assert_body_trace(tracing, wire, started, partial, expected_messages) do
    if tracing do
      assert_receive {:body_trace, %{type: :request} = request}
      assert_exact_dispatched_request(request, wire, started, expected_messages)
      ids = Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])

      assert_receive {:body_trace,
                      %{type: :response_headers, status: 200, headers: headers, ids: ^ids}}

      assert {"x-request-id", "wire-request-73"} in headers
      assert {"retry-after", "11"} in headers
      assert_receive {:body_trace, %{type: :response_data, body: ^partial, ids: ^ids}}

      assert_receive {:body_trace,
                      %{type: :response_end, outcome: :failed, evidence: :available, ids: ^ids}}
    else
      refute_received {:body_trace, _}
    end
  end

  defp body_progress_invoke(gateway, :broker, config),
    do:
      Broker.generate(Broker.new("gpt-4o", gateway), [Message.user("payload-secret")], [], config)

  defp body_progress_invoke(gateway, :broker_object, config),
    do:
      Broker.generate_object(
        Broker.new("gpt-4o", gateway),
        [Message.user("payload-secret")],
        %{"type" => "object"},
        config
      )

  defp body_progress_invoke(gateway, :session, config) do
    session = ChatSession.new(Broker.new("gpt-4o", gateway))
    original = session.messages

    case ChatSession.send(session, "payload-secret", recovery: config.recovery) do
      {:ok, content, updated} ->
        assert Enum.map(updated.messages, & &1.message) ==
                 Enum.map(original, & &1.message) ++
                   [Message.user("payload-secret"), Message.assistant(content)]

        {:ok, content}

      {:error, _} = error ->
        assert session.messages == original
        error
    end
  end

  defp body_progress_invoke(gateway, operation, config), do: invoke(gateway, operation, config)

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      tracing <- [false, true],
      attempts <- [1, 3] do
    @gateway gateway
    @operation operation
    @tracing tracing
    @attempts attempts
    @tag :stalled_completion_boundary
    test "#{gateway} #{operation} stalled body tracing #{tracing} attempts #{attempts} preserves timeout without resend" do
      assert_stalled_completion(@gateway, @operation, @tracing, @attempts)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      winner <- [:finch, :receive_loop] do
    @gateway gateway
    @operation operation
    @winner winner
    @tag :stalled_completion_boundary
    test "#{gateway} #{operation} deterministic #{@winner} body timeout retains its inspectable cause" do
      error = assert_stalled_completion(@gateway, @operation, {:force, @winner}, 3)
      assert_receive {:original_timeout, original}

      case {@operation, @winner} do
        {operation, :finch} when operation in [:events, :legacy] ->
          assert CompletionError.cause(error) == original

        {operation, :receive_loop} when operation in [:events, :legacy] ->
          assert CompletionError.cause(error) == :timeout

        _ ->
          assert %Req.TransportError{reason: :timeout} = CompletionError.cause(error)
      end
    end
  end

  defp assert_stalled_completion(gateway, operation, tracing, attempts) do
    owner = self()
    partial = stalled_partial(gateway, operation)

    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {owner, [{:stream_hold, "HTTP/1.1 200 OK\r\nContent-Length: 9999\r\n\r\n" <> partial}]}}
      )

    assert_receive {:server_port, port}
    configure(gateway, port)

    for key <- ["OPENAI_TIMEOUT", "OLLAMA_TIMEOUT", "OMLX_TIMEOUT"],
        do: System.put_env(key, "100")

    recovery = [
      max_attempts: attempts,
      admission: fn _ ->
        send(owner, :unexpected_admission)
        :allow
      end,
      observer: &send(owner, {:stall_lifecycle, &1})
    ]

    recovery =
      if tracing,
        do: Keyword.put(recovery, :trace_observer, stalled_trace_observer(owner, tracing)),
        else: recovery

    result = stalled_invoke(gateway, operation, CompletionConfig.new(recovery: recovery))
    assert {:error, error} = List.last(result)
    assert_stalled_error(error, result, operation, partial)

    assert [history] = error.history
    assert history.attempt_id == error.attempt_id
    assert history.logical_request_id == error.logical_request_id
    assert history.progress == error.progress
    assert_receive {:stall_lifecycle, %{type: :attempt_started, metadata: started}}
    assert started.attempt_id == error.attempt_id
    assert started.logical_request_id == error.logical_request_id
    assert_receive {:stall_lifecycle, %{type: :attempt_failed, metadata: failed}}
    assert failed.progress == error.progress
    assert failed.attempt_id == error.attempt_id
    assert_receive {:wire_request, wire}
    assert GenServer.call(server, :requests) == [wire]
    [headers, body] = String.split(wire, "\r\n\r\n", parts: 2)
    path = if gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions"
    assert headers =~ "POST #{path} HTTP/1.1"

    assert %{"messages" => [%{"content" => "payload-secret"}], "model" => "gpt-4o"} =
             Jason.decode!(body)

    assert_stalled_trace(tracing, wire, started, partial)
    refute_received :unexpected_admission
    refute_received {:wire_request, _}
    error
  end

  defp stalled_trace_observer(owner, tracing) do
    fn event ->
      send(owner, {:stall_trace, event})

      if event.type == :response_data and is_tuple(tracing) do
        assert_receive {_ref, {:error, %Finch.TransportError{reason: :timeout} = original}} =
                         message,
                       2000

        send(owner, {:original_timeout, original})
        if tracing == {:force, :finch}, do: send(self(), message)
      end

      :ok
    end
  end

  defp assert_stalled_trace(tracing, wire, started, partial) do
    if tracing do
      assert_receive {:stall_trace, %{type: :request} = request}
      assert_exact_dispatched_request(request, wire, started)
      assert_receive {:stall_trace, %{type: :response_data, body: ^partial}}
      assert_receive {:stall_trace, %{type: :response_end, outcome: :failed}}
    else
      refute_received {:stall_trace, _}
    end
  end

  defp assert_stalled_error(error, result, operation, partial) do
    assert error.category == :client_timeout
    refute error.retry_eligible
    assert error.wire_attempt == 1
    assert error.acceptance == :unknown

    if operation in [:events, :legacy] do
      case CompletionError.cause(error) do
        :timeout ->
          :ok

        %Finch.TransportError{reason: :timeout, source: %Mint.TransportError{reason: :timeout}} ->
          :ok
      end

      assert error.progress.headers_received
      assert error.progress.raw_bytes == byte_size(partial)
      assert error.progress.observed.content
      assert error.progress.delivered.content
      assert error.reason == :stream_interrupted
      assert error.phase == :streaming
      assert {:content, "partial"} in result
    else
      assert %Req.TransportError{reason: :timeout} = CompletionError.cause(error)
      assert error.reason == :timeout
      assert error.http_status == 200
      assert error.phase == :streaming
      assert error.progress.headers_received
      assert error.progress.raw_bytes == byte_size(partial)
      refute error.progress.delivered.content
    end
  end

  defp stalled_partial(Ollama, operation) when operation in [:events, :legacy],
    do: Jason.encode!(%{message: %{content: "partial"}, done: false}) <> "\n"

  defp stalled_partial(_gateway, operation) when operation in [:events, :legacy],
    do: "data: " <> Jason.encode!(%{choices: [%{delta: %{content: "partial"}}]}) <> "\n\n"

  defp stalled_partial(_gateway, _operation), do: "partial"

  defp stalled_invoke(gateway, :events, config),
    do:
      Enum.to_list(
        gateway.complete_stream_events("gpt-4o", [Message.user("payload-secret")], config)
      )

  defp stalled_invoke(gateway, :legacy, config),
    do:
      Enum.to_list(
        gateway.complete_stream("gpt-4o", [Message.user("payload-secret")], [], config)
      )

  defp stalled_invoke(gateway, operation, config), do: [invoke(gateway, operation, config)]

  @tag :dispatch_boundary_proof
  test "dispatched cancellation before headers retains exact request and lifecycle identity" do
    server = start_supervised!({ScriptedCompletionServer, {self(), [:hold]}})
    assert_receive {:server_port, port}
    configure(OpenAI, port)
    owner = self()
    cancel = make_ref()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 3,
          cancel_ref: cancel,
          trace_observer: fn event ->
            send(owner, {:boundary_trace, event})
            :ok
          end,
          observer: fn event -> send(owner, {:boundary_lifecycle, event}) end
        ]
      )

    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> invoke(OpenAI, :complete, config) end)
    assert_receive {:wire_request, wire}, 2000
    send(task.pid, {:cancel, cancel})
    assert {:error, error} = Task.await(task, 2000)
    assert error.category == :cancellation
    assert error.wire_attempt == 1
    assert_receive {:boundary_trace, %{type: :request} = request}
    [wire_headers, wire_body] = String.split(wire, "\r\n\r\n", parts: 2)
    assert request.body == wire_body

    assert Jason.decode!(request.body)["messages"] == [
             %{"role" => "user", "content" => "payload-secret"}
           ]

    for {key, value} <- request.headers do
      assert String.downcase(wire_headers) =~ String.downcase("#{key}: #{value}")
    end

    assert request.ids.logical_request_id == error.logical_request_id
    assert request.ids.attempt_id == error.attempt_id
    assert request.ids.wire_attempt == error.wire_attempt
    assert_receive {:boundary_lifecycle, %{type: :attempt_started, metadata: started}}
    assert started.attempt_id == request.ids.attempt_id
    assert started.logical_request_id == request.ids.logical_request_id
    assert GenServer.call(server, :requests) == [wire]
    refute_received {:boundary_trace, %{type: :response_headers}}
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      tracing <- [true, false],
      interruption <- [:closed, :timeout],
      status <- [401, 503] do
    @gateway gateway
    @operation operation
    @tracing tracing
    @interruption interruption
    @status status
    @tag :interrupted_status_boundary
    test "#{gateway} #{operation} interrupted #{status} #{interruption} tracing #{tracing} retains HTTP evidence without transport retry" do
      owner = self()
      partial = "partial-error-secret"

      wire_response =
        String.replace(
          response(@status, partial),
          "Content-Length: #{byte_size(partial)}",
          "Content-Length: 999"
        )

      scripted =
        if @interruption == :closed, do: wire_response, else: {:stream_hold, wire_response}

      server = start_supervised!({ScriptedCompletionServer, {self(), [scripted]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)

      for key <- ["OPENAI_TIMEOUT", "OLLAMA_TIMEOUT", "OMLX_TIMEOUT"],
          do: System.put_env(key, "150")

      recovery = [
        max_attempts: 3,
        retryable_categories: [:transport, :http],
        retryable_statuses: [],
        admission: fn _ -> :allow end,
        observer: &send(owner, {:status_lifecycle, &1})
      ]

      recovery =
        if @tracing,
          do:
            Keyword.put(recovery, :trace_observer, fn event ->
              send(owner, {:status_trace, event})
              :ok
            end),
          else: recovery

      assert {:error, error} =
               boundary_invoke(@gateway, @operation, CompletionConfig.new(recovery: recovery))

      assert error.category == :http
      assert error.http_status == @status
      assert error.provider_request_id == "wire-request-73"
      assert error.retry_after == {:delay_seconds, 11}
      assert error.progress.headers_received
      assert error.phase == :streaming
      assert error.progress.raw_bytes == byte_size(partial)
      assert error.retry_eligible == (@status == 503)
      assert error.wire_attempt == 1
      assert [history] = error.history
      assert history.http_status == @status
      assert history.progress == error.progress
      assert history.attempt_id == error.attempt_id
      assert_receive {:status_lifecycle, %{type: :attempt_started, metadata: started}}
      assert started.attempt_id == error.attempt_id
      assert started.logical_request_id == error.logical_request_id
      assert_receive {:status_lifecycle, %{type: :attempt_failed, metadata: failed}}
      assert failed.http_status == @status
      assert failed.progress == error.progress
      assert failed.attempt_id == error.attempt_id
      assert_receive {:wire_request, wire}
      assert GenServer.call(server, :requests) == [wire]

      if @tracing do
        assert_receive {:status_trace, %{type: :request} = request}
        assert_exact_dispatched_request(request, wire, started)

        assert_receive {:status_trace,
                        %{type: :response_headers, status: status, headers: headers}}

        assert status == @status
        assert {"x-request-id", "wire-request-73"} in headers
        assert_receive {:status_trace, %{type: :response_data, body: ^partial}}

        assert_receive {:status_trace,
                        %{type: :response_end, outcome: :failed, evidence: :available}}
      else
        refute_received {:status_trace, _}
      end

      refute inspect(error) =~ "secret"
      refute Jason.encode!(error) =~ "secret"
      refute_receive {:wire_request, _}, 30
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      attempt <- [1, 2] do
    @gateway gateway
    @operation operation
    @attempt attempt
    test "#{gateway} #{operation} dispatched attempt #{attempt} cancelled before headers retains exact independent request evidence" do
      owner = self()
      responses = if @attempt == 1, do: [:hold], else: [response(503, "failure-secret"), :hold]
      server = start_supervised!({ScriptedCompletionServer, {self(), responses}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      cancel = make_ref()

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 3,
            cancel_ref: cancel,
            base_delay: 0,
            sleeper: fn _ -> :ok end,
            admission: fn _ -> :allow end,
            trace_observer: fn event ->
              send(owner, {:dispatch_trace, event})
              :ok
            end,
            observer: &send(owner, {:dispatch_lifecycle, &1})
          ]
        )

      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          boundary_invoke(@gateway, @operation, config)
        end)

      wires =
        for _ <- 1..@attempt do
          assert_receive {:wire_request, wire}, 2000
          wire
        end

      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert error.category == :cancellation
      assert error.wire_attempt == @attempt

      traces =
        for _ <- 1..@attempt do
          assert_receive {:dispatch_trace, %{type: :request} = trace}
          trace
        end

      for {trace, wire} <- Enum.zip(traces, wires) do
        assert_receive {:dispatch_lifecycle, %{type: :attempt_started, metadata: started}}
        assert_exact_dispatched_request(trace, wire, started)
        assert trace.ids.logical_request_id == error.logical_request_id
        assert is_binary(trace.ids.attempt_id) and byte_size(trace.ids.attempt_id) > 10
      end

      assert List.last(traces).ids.attempt_id == error.attempt_id
      assert List.last(traces).ids.wire_attempt == error.wire_attempt
      cancelled_id = error.attempt_id

      refute_received {:dispatch_trace,
                       %{type: :response_headers, ids: %{attempt_id: ^cancelled_id}}}

      refute_received {:dispatch_trace,
                       %{type: :response_data, ids: %{attempt_id: ^cancelled_id}}}

      assert length(Enum.uniq(Enum.map(traces, & &1.ids.attempt_id))) == @attempt

      for history <- error.history do
        assert Enum.any?(traces, &(&1.ids.attempt_id == history.attempt_id))
        assert history.logical_request_id == error.logical_request_id
      end

      assert GenServer.call(server, :requests) == wires
      if @attempt == 2, do: assert(hd(wires) == List.last(wires))
      refute_receive {:wire_request, _}, 30
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy] do
    @gateway gateway
    @operation operation
    test "#{gateway} #{operation} interrupted 503 retries only as admitted HTTP status with immutable bytes" do
      partial = "partial-error-secret"

      truncated =
        String.replace(
          response(503, partial),
          "Content-Length: #{byte_size(partial)}",
          "Content-Length: 999"
        )

      server = start_supervised!({ScriptedCompletionServer, {self(), [truncated, truncated]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            retryable_categories: [:http],
            retryable_statuses: [503],
            base_delay: 0,
            sleeper: fn _ -> :ok end,
            admission: fn context ->
              assert context.failure.http_status == 503
              assert context.failure.progress.raw_bytes == byte_size(partial)
              send(owner, {:status_admission, context})
              :allow
            end
          ]
        )

      assert {:error, error} = boundary_invoke(@gateway, @operation, config)
      assert error.category == :http
      assert error.wire_attempt == 2
      assert_receive {:status_admission, context}
      assert context.next_attempt == 2
      assert [first, second] = GenServer.call(server, :requests)
      assert first == second
      assert [initial, final] = error.history
      assert initial.http_status == 503 and final.http_status == 503
      assert initial.attempt_id != final.attempt_id
      assert final.attempt_id == error.attempt_id
      assert initial.logical_request_id == final.logical_request_id
    end
  end

  defp assert_exact_dispatched_request(
         trace,
         wire,
         started,
         expected_messages \\ [%{"role" => "user", "content" => "payload-secret"}]
       ) do
    [headers, body] = String.split(wire, "\r\n\r\n", parts: 2)
    assert trace.body == body
    assert Jason.decode!(body)["messages"] == expected_messages
    assert byte_size(body) > 0

    received_headers =
      for line <- tl(String.split(headers, "\r\n")) do
        [key, value] = String.split(line, ": ", parts: 2)
        {String.downcase(key), value}
      end

    for {key, value} <- trace.headers do
      assert {String.downcase(key), value} in received_headers
    end

    assert trace.ids.logical_request_id =~ ~r/\A[0-9a-f-]{36}\z/
    assert trace.ids.attempt_id =~ ~r/\A[0-9a-f-]{36}\z/

    assert Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt]) == trace.ids
  end

  defp boundary_invoke(gateway, :events, config) do
    [{:error, error}] =
      gateway.complete_stream_events("gpt-4o", [Message.user("payload-secret")], config)
      |> Enum.to_list()

    {:error, error}
  end

  defp boundary_invoke(gateway, :legacy, config) do
    [{:error, error}] =
      gateway.complete_stream("gpt-4o", [Message.user("payload-secret")], [], config)
      |> Enum.to_list()

    {:error, error}
  end

  defp boundary_invoke(gateway, operation, config), do: invoke(gateway, operation, config)

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      outcome <- [:retry_success, :exhaustion, :malformed, :capture_failure] do
    @gateway gateway
    @operation operation
    @outcome outcome
    test "#{gateway} #{@operation} exact trace #{@outcome} preserves wire bytes and identity" do
      owner = self()
      failure = "response-secret"

      content =
        if @operation == :complete_object,
          do: ~s({"answer":"response-secret"}),
          else: "response-secret"

      success =
        if @gateway == Ollama,
          do: Jason.encode!(%{message: %{content: content}, done: true}),
          else: Jason.encode!(%{choices: [%{message: %{content: content}}]})

      bodies =
        case @outcome do
          :retry_success -> [{503, failure}, {200, success}]
          :exhaustion -> [{503, failure}, {503, failure}]
          :malformed -> [{200, "invalid-response-secret"}]
          :capture_failure -> [{200, success}]
        end

      server =
        start_supervised!(
          {ScriptedCompletionServer,
           {self(), Enum.map(bodies, fn {status, body} -> response(status, body) end)}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            base_delay: 0,
            admission: fn _ -> :allow end,
            sleeper: fn _ -> :ok end,
            trace_observer: fn event ->
              send(owner, {:exact_trace, event})

              if @outcome == :capture_failure and event.type == :response_end,
                do: raise("capture-secret")

              :ok
            end,
            observer: &send(owner, {:exact_lifecycle, &1})
          ]
        )

      logs =
        capture_log(fn ->
          result = invoke(@gateway, @operation, config)
          send(owner, {:exact_result, result})

          case @outcome do
            :retry_success ->
              assert {:ok, _} = result

            outcome ->
              assert {:error, error} = result
              assert_capture_outcome(outcome, error)
              assert error.wire_attempt == length(bodies)
              refute inspect(error) =~ "secret"
              refute Jason.encode!(error) =~ "secret"
          end
        end)

      refute logs =~ "secret"
      traces = exact_messages(:exact_trace)
      lifecycle = exact_messages(:exact_lifecycle)
      requests = GenServer.call(server, :requests)
      assert length(requests) == length(bodies)
      grouped = Enum.group_by(traces, & &1.ids.wire_attempt)

      for {{status, body}, number} <- Enum.with_index(bodies, 1) do
        events = grouped[number]
        [request_event] = Enum.filter(events, &(&1.type == :request))
        [_, encoded] = String.split(Enum.at(requests, number - 1), "\r\n\r\n", parts: 2)
        assert request_event.body == encoded
        assert request_event.method == :post

        assert request_event.url =~
                 if(@gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions")

        [headers] = Enum.filter(events, &(&1.type == :response_headers))
        assert headers.status == status
        assert {"x-request-id", "wire-request-73"} in headers.headers

        assert Enum.filter(events, &(&1.type == :response_data))
               |> Enum.map(& &1.body)
               |> IO.iodata_to_binary() == body

        assert Enum.all?(events, &(&1.ids == request_event.ids))
        assert Enum.count(events, &(&1.type == :response_end)) == 1
        assert Enum.map(Enum.take(events, 2), & &1.type) == [:request, :response_headers]
        assert Enum.all?(Enum.slice(events, 2, length(events) - 3), &(&1.type == :response_data))
        assert List.last(events).type == :response_end
        assert List.last(events).outcome == if(status == 200, do: :complete, else: :failed)

        [started] =
          Enum.filter(
            lifecycle,
            &(&1.type == :attempt_started and &1.metadata.wire_attempt == number)
          )

        assert Map.take(started.metadata, [:logical_request_id, :attempt_id, :wire_attempt]) ==
                 request_event.ids

        assert_exact_dispatched_request(
          request_event,
          Enum.at(requests, number - 1),
          started.metadata
        )
      end

      ids = Enum.filter(traces, &(&1.type == :request)) |> Enum.map(& &1.ids)
      assert length(Enum.uniq(Enum.map(ids, & &1.logical_request_id))) == 1
      assert length(Enum.uniq(Enum.map(ids, & &1.attempt_id))) == length(bodies)
      assert_receive {:exact_result, result}
      assert_trace_history(result, ids)
      refute inspect(lifecycle) =~ "secret"
      if length(requests) == 2, do: assert(Enum.at(requests, 0) == Enum.at(requests, 1))
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      evidence <- [:empty, :unavailable, :partial] do
    @gateway gateway
    @operation operation
    @evidence evidence
    test "#{gateway} #{operation} exact trace distinguishes #{evidence} response evidence" do
      owner = self()

      response =
        case @evidence do
          :empty ->
            response(200, "")

          :unavailable ->
            ""

          :partial ->
            String.replace(
              response(200, "partial-response-secret"),
              "Content-Length: 23",
              "Content-Length: 123"
            )
        end

      server = start_supervised!({ScriptedCompletionServer, {self(), [response]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)

      config =
        CompletionConfig.new(
          recovery: [
            trace_observer: fn event ->
              send(owner, {:evidence_trace, event})
              :ok
            end
          ]
        )

      assert {:error, error} = invoke(@gateway, @operation, config)

      if @evidence == :partial do
        assert error.category == :transport
        assert error.retry_eligible
        assert %Req.TransportError{reason: :closed} = CompletionError.cause(error)
      end

      traces = exact_messages(:evidence_trace)

      data =
        Enum.filter(traces, &(&1.type == :response_data))
        |> Enum.map(& &1.body)
        |> IO.iodata_to_binary()

      expected = if @evidence == :partial, do: "partial-response-secret", else: ""
      assert data == expected
      [terminal] = Enum.filter(traces, &(&1.type == :response_end))

      assert terminal.evidence ==
               if(@evidence == :unavailable, do: :unavailable, else: :available)

      [request_event] = Enum.filter(traces, &(&1.type == :request))
      [request] = GenServer.call(server, :requests)
      [_, encoded] = String.split(request, "\r\n\r\n", parts: 2)
      assert request_event.body == encoded
      assert request_event.ids.attempt_id == error.attempt_id
      assert request_event.ids.logical_request_id == error.logical_request_id
      refute inspect(error) =~ "secret"
    end
  end

  for stage <- [:before_dispatch, :during_capture], operation <- [:complete, :complete_object] do
    @stage stage
    @operation operation
    test "ordinary #{operation} exact trace cancellation #{stage} preserves dispatch accounting" do
      owner = self()
      body = Jason.encode!(%{choices: [%{message: %{content: ~s({"answer":"response-secret"})}}]})
      server = start_supervised!({ScriptedCompletionServer, {self(), [response(200, body)]}})
      assert_receive {:server_port, port}
      configure(OpenAI, port)
      cancel = make_ref()

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 3,
            cancel_ref: cancel,
            trace_observer: fn event ->
              send(owner, {:ordinary_cancel_trace, event})

              if @stage == :during_capture and event.type == :response_data do
                send(owner, {:ordinary_capturing, self()})

                receive do
                  :release_capture -> :ok
                end
              end

              :ok
            end
          ]
        )

      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          if @stage == :before_dispatch, do: send(self(), {:cancel, cancel})
          invoke(OpenAI, @operation, config)
        end)

      if @stage == :during_capture do
        assert_receive {:ordinary_capturing, worker}, 2000
        monitor = Process.monitor(worker)
        send(task.pid, {:cancel, cancel})
        assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2000
      end

      assert {:error, error} = Task.await(task, 2000)
      assert error.category == :cancellation
      count = if @stage == :before_dispatch, do: 0, else: 1
      assert error.wire_attempt == count
      assert length(GenServer.call(server, :requests)) == count
      if count == 0, do: refute_received({:ordinary_cancel_trace, _})
      refute inspect(error) =~ "secret"
    end
  end

  for failure <- [:return, :throw, :exit] do
    @failure failure
    test "exact trace observer #{failure} cannot report success or resend" do
      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(503, "response-secret")]}}
        )

      assert_receive {:server_port, port}
      configure(OpenAI, port)

      config =
        CompletionConfig.new(recovery: [max_attempts: 3, trace_observer: trace_failure(@failure)])

      assert {:error, error} = invoke(OpenAI, :complete, config)
      assert error.reason == :capture_failed
      assert error.wire_attempt == 1
      assert length(GenServer.call(server, :requests)) == 1
      refute inspect(error) =~ "secret"
      refute Jason.encode!(error) =~ "secret"
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], entrypoint <- [:broker, :session] do
    @gateway gateway
    @entrypoint entrypoint
    test "#{gateway} ordinary #{entrypoint} exact trace capture failure prevents tool execution" do
      owner = self()

      call =
        if @gateway == Ollama,
          do: %{function: %{name: "count", arguments: %{value: "tool-secret"}}},
          else: %{
            id: "call-17",
            type: "function",
            function: %{name: "count", arguments: ~s({"value":"tool-secret"})}
          }

      message = %{content: "", tool_calls: [call]}

      body =
        if @gateway == Ollama,
          do: Jason.encode!(%{message: message, done: true}),
          else: Jason.encode!(%{choices: [%{message: message}]})

      server = start_supervised!({ScriptedCompletionServer, {self(), [response(200, body)]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 3,
            trace_observer: fn event ->
              send(owner, {:forwarded_trace, event})
              if event.type == :response_end, do: raise("capture-secret")
              :ok
            end
          ]
        )

      tool = %Mojentic.TestSupport.CountingTool{owner: owner}
      broker = Broker.new("gpt-4o", @gateway)

      result =
        case @entrypoint do
          :broker ->
            Broker.generate(broker, [Message.user("payload-secret")], [tool], config)

          :session ->
            session = ChatSession.new(broker, tools: [tool])
            ChatSession.send(session, "payload-secret", recovery: config.recovery)
        end

      assert {:error, error} = result
      assert error.reason == :capture_failed
      refute_received {:tool_executed, _}
      traces = exact_messages(:forwarded_trace)
      [request_event] = Enum.filter(traces, &(&1.type == :request))
      [request] = GenServer.call(server, :requests)
      [_, encoded] = String.split(request, "\r\n\r\n", parts: 2)
      assert request_event.body == encoded

      assert Enum.filter(traces, &(&1.type == :response_data))
             |> Enum.map(& &1.body)
             |> IO.iodata_to_binary() == body

      assert request_event.ids.attempt_id == error.attempt_id
      refute inspect(error) =~ "secret"
      refute Jason.encode!(error) =~ "secret"
    end
  end

  defp trace_failure(:return), do: fn _ -> {:error, "capture-secret"} end
  defp trace_failure(:throw), do: fn _ -> throw("capture-secret") end
  defp trace_failure(:exit), do: fn _ -> exit("capture-secret") end

  defp assert_trace_history({:ok, _}, _ids), do: :ok

  defp assert_trace_history({:error, error}, ids) do
    assert Enum.map(
             error.history,
             &Map.take(&1, [:logical_request_id, :attempt_id, :wire_attempt])
           ) == ids
  end

  defp assert_capture_outcome(:capture_failure, error),
    do: assert(error.reason == :capture_failed)

  defp assert_capture_outcome(_, _), do: :ok

  defp exact_messages(tag, acc \\ []) do
    receive do
      {^tag, event} -> exact_messages(tag, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @tag :decoding_proof
  test "OpenAI complete_object real Req retains invalid structured content and exact lifecycle" do
    body = Jason.encode!(%{choices: [%{message: %{content: "response-secret"}}]})

    server =
      start_supervised!(
        {ScriptedCompletionServer, {self(), [response(200, body), response(200, "{}")]}}
      )

    assert_receive {:server_port, port}
    configure(OpenAI, port)
    owner = self()

    config =
      CompletionConfig.new(
        recovery: [max_attempts: 3, observer: &send(owner, {:decoding_event, &1})]
      )

    logs =
      capture_log(fn ->
        assert {:error, %CompletionError{} = error} = invoke(OpenAI, :complete_object, config)

        DecodingEvidence.assert_failure(
          error,
          OpenAI,
          :complete_object,
          :invalid_structured_content,
          body,
          :invalid_json_object,
          %{DecodingEvidence.empty() | content: true},
          {"wire-request-73", {:delay_seconds, 11}}
        )
      end)

    assert_receive {:wire_request, request}
    assert_payload(request, OpenAI, :complete_object)
    assert GenServer.call(server, :requests) == [request]
    refute_received {:wire_request, _}

    for secret <- [
          "payload-secret",
          "response-secret",
          "credential-secret",
          "tool-secret",
          "reasoning-secret"
        ],
        do: refute(logs =~ secret)
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      kind <- [
        :invalid_outer_json,
        :invalid_structured_content,
        :provider_error,
        :parser_exception
      ],
      kind != :invalid_structured_content or operation == :complete_object do
    @gateway gateway
    @operation operation
    @kind kind

    test "#{gateway} #{operation} real Req decoding #{kind} retains exact evidence without resends" do
      {body, cause, observed} = DecodingEvidence.fixture(@gateway, @operation, @kind)

      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(200, body), response(200, "{}")]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()

      config =
        CompletionConfig.new(
          recovery: [max_attempts: 3, observer: &send(owner, {:decoding_event, &1})]
        )

      logs =
        capture_log(fn ->
          assert {:error, error} = invoke(@gateway, @operation, config)

          DecodingEvidence.assert_failure(
            error,
            @gateway,
            @operation,
            @kind,
            body,
            cause,
            observed,
            {"wire-request-73", {:delay_seconds, 11}}
          )
        end)

      DecodingEvidence.assert_private(logs)
      assert_receive {:wire_request, request}
      assert_payload(request, @gateway, @operation)
      [headers, payload] = String.split(request, "\r\n\r\n", parts: 2)
      assert String.downcase(headers) =~ "content-type: application/json"
      assert String.downcase(headers) =~ "content-length: #{byte_size(payload)}"

      if @gateway != Ollama,
        do: assert(String.downcase(headers) =~ "authorization: bearer credential-secret")

      assert GenServer.call(server, :requests) == [request]
      refute_received {:wire_request, _}
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    test "#{gateway} #{operation} Req closure retains ambiguous acceptance and exact cause" do
      server = start_supervised!({ScriptedCompletionServer, {self(), [""]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()
      config = CompletionConfig.new(recovery: [observer: &send(owner, {:transport_event, &1})])
      assert {:error, %CompletionError{} = error} = invoke(@gateway, @operation, config)
      assert error.provider == provider(@gateway)
      assert error.operation == @operation
      assert %Req.TransportError{reason: :closed} = CompletionError.cause(error)
      assert_transport(error, :transport, :unknown, :unknown, :transport_failure, true)
      assert_receive {:wire_request, request}
      assert_payload(request, @gateway, @operation)
      assert GenServer.call(server, :requests) == [request]
      refute_received {:wire_request, _}
    end

    test "#{gateway} #{operation} Req receive timeout preserves uncertainty without resend" do
      server = start_supervised!({ScriptedCompletionServer, {self(), [:hold]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)

      for key <- ["OPENAI_TIMEOUT", "OLLAMA_TIMEOUT", "OMLX_TIMEOUT"],
          do: System.put_env(key, "100")

      owner = self()
      config = CompletionConfig.new(recovery: [observer: &send(owner, {:transport_event, &1})])
      assert {:error, %CompletionError{} = error} = invoke(@gateway, @operation, config)
      assert error.provider == provider(@gateway)
      assert error.operation == @operation
      assert %Req.TransportError{reason: :timeout} = CompletionError.cause(error)
      assert_transport(error, :client_timeout, :unknown, :unknown, :timeout, false)
      assert_receive {:wire_request, request}
      assert_payload(request, @gateway, @operation)
      assert GenServer.call(server, :requests) == [request]
      refute_received {:wire_request, _}
    end

    test "#{gateway} #{operation} Req connection refusal proves nonacceptance" do
      # Bound but not listening: the port stays reserved throughout the probe.
      {:ok, socket} = :socket.open(:inet, :stream, :tcp)
      :ok = :socket.bind(socket, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
      on_exit(fn -> :socket.close(socket) end)
      {:ok, %{port: port}} = :socket.sockname(socket)
      configure(@gateway, port)
      owner = self()
      config = CompletionConfig.new(recovery: [observer: &send(owner, {:transport_event, &1})])
      assert {:error, %CompletionError{} = error} = invoke(@gateway, @operation, config)
      assert error.provider == provider(@gateway)
      assert error.operation == @operation
      assert %Req.TransportError{reason: :econnrefused} = CompletionError.cause(error)
      assert_transport(error, :transport, :connecting, :no, :connection_refused, true)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      status <- [429, 500, 502, 503, 504, 400, 401] do
    @gateway gateway
    @operation operation
    @status status
    test "#{gateway} #{operation} Req sees one exact request and never retries HTTP #{status}" do
      body = ~s({ "error": { "code": "overloaded", "message": "response-secret" } })

      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(@status, body), response(200, "{}")]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)
      config = CompletionConfig.new(recovery: [])

      logs =
        capture_log(fn ->
          messages = [Message.user("payload-secret")]

          result =
            case @operation do
              :complete ->
                @gateway.complete("gpt-4o", messages, [], config)

              :complete_object ->
                @gateway.complete_object("gpt-4o", messages, %{"type" => "object"}, config)
            end

          assert {:error, %CompletionError{} = error} = result
          assert error.http_status == @status
          assert error.category == :http
          assert error.reason == :http_status
          assert error.acceptance == :unknown
          assert error.phase == :awaiting_headers
          assert error.retry_eligible == @status in [429, 500, 502, 503, 504]
          assert error.provider_request_id == "wire-request-73"
          assert error.provider_code == "overloaded"
          assert error.retry_after == {:delay_seconds, 11}
          assert error.progress.raw_bytes == byte_size(body)
          assert {:ok, %{body: ^body}} = CompletionError.cause(error)
          refute inspect(error) =~ "response-secret"
          refute Jason.encode!(error) =~ "response-secret"
        end)

      assert_receive {:wire_request, request}
      [headers, payload] = String.split(request, "\r\n\r\n", parts: 2)
      path = if @gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions"
      assert headers =~ "POST #{path} HTTP/1.1"
      assert headers =~ "content-type: application/json"
      if @gateway != Ollama, do: assert(headers =~ "authorization: Bearer credential-secret")

      assert Jason.decode!(payload)["messages"] == [
               %{"role" => "user", "content" => "payload-secret"}
             ]

      assert Jason.decode!(payload)["model"] == "gpt-4o"
      assert GenServer.call(server, :requests) == [request]
      refute_received {:wire_request, _}

      for secret <- ["credential-secret", "payload-secret", "response-secret"],
          do: refute(logs =~ secret)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    test "#{gateway} real Req closure propagates through broker APIs and session with caller history intact" do
      server = start_supervised!({ScriptedCompletionServer, {self(), ["", "", "", ""]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      broker = Broker.new("gpt-4o", @gateway)
      messages = [Message.user("payload-secret")]
      owner = self()
      config = CompletionConfig.new(recovery: [observer: &send(owner, {:transport_event, &1})])

      calls = [
        {:complete, fn -> Broker.generate(broker, messages, nil, config) end},
        {:complete, fn -> Broker.generate_response(broker, messages, nil, config) end},
        {:complete_object,
         fn -> Broker.generate_object(broker, messages, %{"type" => "object"}, config) end}
      ]

      requests =
        Enum.map(calls, fn {operation, call} ->
          assert {:error, %CompletionError{} = error} = call.()
          assert %Req.TransportError{reason: :closed} = CompletionError.cause(error)
          assert error.provider == provider(@gateway)
          assert error.operation == operation
          assert_transport(error, :transport, :unknown, :unknown, :transport_failure, true)
          assert_receive {:wire_request, request}
          assert_payload(request, @gateway, operation)
          request
        end)

      session = ChatSession.new(broker)
      history = session.messages

      assert {:error, %CompletionError{} = error} =
               ChatSession.send(session, "payload-secret", recovery: config.recovery)

      assert %Req.TransportError{reason: :closed} = CompletionError.cause(error)
      assert_transport(error, :transport, :unknown, :unknown, :transport_failure, true)
      assert_receive {:wire_request, request}

      assert_payload(request, @gateway, :complete, [
        %{"role" => "system", "content" => session.system_prompt},
        %{"role" => "user", "content" => "payload-secret"}
      ])

      assert GenServer.call(server, :requests) == requests ++ [request]
      assert session.messages == history
      assert messages == [Message.user("payload-secret")]
      refute_received {:wire_request, _}
    end
  end

  test "broker and session tracing omit payload and response secrets on completion failures" do
    tracer = start_supervised!({TracerSystem, []})

    _server =
      start_supervised!(
        {ScriptedCompletionServer,
         {self(), [response(503, "response-secret"), response(503, "response-secret")]}}
      )

    assert_receive {:server_port, port}
    configure(OpenAI, port)
    broker = Broker.new("gpt-4o", OpenAI, tracer: tracer)
    config = CompletionConfig.new(recovery: [])

    assert {:error, %CompletionError{}} =
             Broker.generate(broker, [Message.user("payload-secret")], nil, config)

    session = ChatSession.new(broker)

    assert {:error, %CompletionError{}} =
             ChatSession.send(session, "payload-secret", recovery: [])

    events = TracerSystem.get_events(tracer)
    assert length(events) == 2
    refute inspect(events) =~ "payload-secret"
    refute inspect(events) =~ "response-secret"
  end

  defp provider(OpenAI), do: :openai
  defp provider(Ollama), do: :ollama
  defp provider(OMLX), do: :omlx

  defp invoke(gateway, :complete, config),
    do: gateway.complete("gpt-4o", [Message.user("payload-secret")], [], config)

  defp invoke(gateway, :complete_object, config),
    do:
      gateway.complete_object(
        "gpt-4o",
        [Message.user("payload-secret")],
        %{"type" => "object"},
        config
      )

  defp assert_transport(error, category, phase, acceptance, reason, eligible) do
    assert error.category == category
    assert error.phase == phase
    assert error.acceptance == acceptance
    assert error.reason == reason
    assert error.retry_eligible == eligible
    assert error.http_status == nil
    assert error.wire_attempt == 1
    assert error.resend_permission == :not_granted
    assert error.retry_after == :absent
    assert error.provider_code == nil
    assert error.provider_request_id == nil
    empty = %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

    assert error.progress == %{
             headers_received: false,
             raw_bytes: 0,
             observed: empty,
             delivered: empty
           }

    safe = CompletionError.safe_metadata(error)

    for rendered <- [inspect(error), Jason.encode!(error), inspect(safe)],
        secret <- ["payload-secret", "credential-secret", "response-secret"] do
      refute rendered =~ secret
    end

    assert error.history == [Map.delete(safe, :history)]
    assert UUID.info!(error.logical_request_id)[:version] == 4
    assert UUID.info!(error.attempt_id)[:version] == 4
    refute error.logical_request_id == error.attempt_id
    assert_receive {:transport_event, %{type: :attempt_started, metadata: started}}
    assert started.logical_request_id == error.logical_request_id
    assert started.attempt_id == error.attempt_id
    assert_receive {:transport_event, %{type: :attempt_failed, metadata: ^safe}}
    assert_receive {:transport_event, %{type: :exhausted, metadata: ^safe}}
    refute_received {:transport_event, _}
  end

  defp assert_payload(
         request,
         gateway,
         operation,
         messages \\ [%{"role" => "user", "content" => "payload-secret"}]
       ) do
    [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    path = if gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions"
    assert headers =~ "POST #{path} HTTP/1.1"
    payload = Jason.decode!(body)

    base = %{
      "model" => "gpt-4o",
      "messages" => messages
    }

    base =
      if gateway == Ollama do
        Map.merge(base, %{
          "stream" => false,
          "options" => %{"temperature" => 1.0, "num_ctx" => 32_768, "num_predict" => 16_384}
        })
      else
        Map.merge(base, %{"temperature" => 1.0, "max_tokens" => 16_384})
      end

    expected =
      case {gateway, operation} do
        {_, :complete} ->
          base

        {Ollama, :complete_object} ->
          Map.put(base, "format", %{"type" => "object"})

        {_, :complete_object} ->
          Map.put(base, "response_format", %{
            "type" => "json_schema",
            "json_schema" => %{"name" => "response", "schema" => %{"type" => "object"}}
          })
      end

    assert payload == expected
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    test "#{gateway} #{operation} real Req 503 recovers with identical full payload and correlated lifecycle" do
      body = successful_body(@gateway, @operation)

      server =
        start_supervised!(
          {ScriptedCompletionServer,
           {self(), [response(503, "response-secret"), response(200, body)]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            base_delay: 0,
            sleeper: fn delay ->
              send(owner, {:delay, delay})
              :ok
            end,
            admission: fn context ->
              send(owner, {:admitted, context})
              :allow
            end,
            observer: &send(owner, {:lifecycle, &1})
          ]
        )

      assert {:ok, _} = invoke(@gateway, @operation, config)
      assert_receive {:wire_request, first}
      assert_receive {:wire_request, second}
      assert_payload(first, @gateway, @operation)
      assert second == first
      assert GenServer.call(server, :requests) == [first, second]
      assert_receive {:delay, 11_000}
      assert_receive {:admitted, context}
      assert context.failure.http_status == 503
      assert context.failure.provider_request_id == "wire-request-73"
      assert context.failure.retry_after == %{kind: :delay_seconds, value: 11}

      events =
        for _ <- 1..8 do
          assert_receive {:lifecycle, event}
          event
        end

      assert Enum.map(events, & &1.type) == [
               :attempt_started,
               :attempt_failed,
               :admission_pending,
               :admission_allowed,
               :backoff_started,
               :retry_started,
               :attempt_started,
               :attempt_succeeded
             ]

      [started, failed, _, _, _, retrying, resent, succeeded] = events
      assert retrying.metadata.wire_attempt == 1
      assert retrying.metadata.next_attempt == 2
      assert started.metadata.attempt_id == failed.metadata.attempt_id
      assert resent.metadata.attempt_id == succeeded.metadata.attempt_id
      refute started.metadata.attempt_id == resent.metadata.attempt_id

      assert Enum.uniq(Enum.map(events, & &1.metadata.logical_request_id)) == [
               context.logical_request_id
             ]

      assert succeeded.metadata.wire_attempt == 2
      refute inspect(events) =~ "response-secret"
      refute inspect(events) =~ "payload-secret"
    end

    test "#{gateway} #{operation} real Req persistent 504 exhausts with ordered exact evidence" do
      failures =
        for n <- 1..3,
            do:
              response(504, "response-secret")
              |> String.replace("wire-request-73", "request-#{n}")

      server = start_supervised!({ScriptedCompletionServer, {self(), failures}})
      assert_receive {:server_port, port}
      configure(@gateway, port)

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 3,
            base_delay: 0,
            admission: fn _ -> :allow end,
            sleeper: fn _ -> :ok end
          ]
        )

      assert {:error, error} = invoke(@gateway, @operation, config)
      assert error.wire_attempt == 3
      assert error.http_status == 504
      assert error.provider_request_id == "request-3"

      assert Enum.map(error.history, & &1.provider_request_id) == [
               "request-1",
               "request-2",
               "request-3"
             ]

      assert Enum.map(error.history, & &1.wire_attempt) == [1, 2, 3]

      assert Enum.map(error.history, & &1.retry_after) ==
               List.duplicate(%{kind: :delay_seconds, value: 11}, 3)

      assert Enum.uniq(Enum.map(error.history, & &1.attempt_id)) |> length() == 3
      requests = GenServer.call(server, :requests)
      assert length(requests) == 3
      Enum.each(requests, &assert_payload(&1, @gateway, @operation))
      assert Enum.uniq(requests) |> length() == 1
      refute inspect(error) =~ "response-secret"
    end
  end

  for {header, minimum} <- [
        {"2", 2000},
        {"Thu, 01 Jan 2026 00:00:03 GMT", 3000},
        {"Wed, 31 Dec 2025 23:59:00 GMT", 0},
        {"garbage", 0}
      ],
      gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    @header header
    @minimum minimum
    test "#{gateway} #{operation} real Req Retry-After #{@header} respects observed wall clock and policy minimum" do
      owner = self()

      server =
        start_supervised!(
          {ScriptedCompletionServer,
           {self(),
            [
              response(429, "response-secret")
              |> String.replace("Retry-After: 11", "Retry-After: #{@header}"),
              response(200, successful_body(@gateway, @operation))
            ]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            observer: &send(owner, {:retry_after_event, &1}),
            admission: fn _ -> :allow end,
            base_delay: 10,
            jitter: fn ceiling ->
              assert ceiling == 10
              7
            end,
            wall_clock: fn -> ~U[2026-01-01 00:00:00Z] end,
            sleeper: fn delay ->
              send(owner, {:delay, delay})
              :ok
            end
          ]
        )

      assert {:ok, _} = invoke(@gateway, @operation, config)
      assert_receive {:retry_after_event, %{type: :attempt_failed, metadata: failure}}
      assert failure.http_status == 429
      assert failure.provider_request_id == "wire-request-73"
      assert failure.retry_after == expected_retry_after(@header)
      assert failure.phase == :awaiting_headers
      assert failure.acceptance == :unknown
      assert failure.progress.raw_bytes == byte_size("response-secret")
      assert failure.wire_attempt == 1
      assert_receive {:delay, delay}
      assert delay == max(7, @minimum)
      [first, second] = GenServer.call(server, :requests)
      assert first == second
      assert_payload(first, @gateway, @operation)
    end
  end

  for {policy, reason} <- [
        {[delay_ceiling: 100], :retry_after_ceiling},
        {[budget: 11_000, clock: :zero], :deadline},
        {[deadline: 0, clock: :zero], :deadline},
        {[], :admission_required},
        {[admission: :reject], :rejected}
      ],
      gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      gateway != OpenAI or reason != :admission_required do
    @gateway gateway
    @operation operation
    @policy policy
    @reason reason
    test "#{gateway} #{operation} real Req local recovery refuses #{@reason} with #{inspect(Keyword.keys(policy))}" do
      server =
        start_supervised!(
          {ScriptedCompletionServer,
           {self(),
            [
              response(504, "response-secret"),
              response(200, successful_body(@gateway, @operation))
            ]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)

      policy =
        Enum.map(@policy, fn
          {:clock, :zero} -> {:clock, fn -> 0 end}
          {:admission, :reject} -> {:admission, fn _ -> :reject end}
          option -> option
        end)

      policy = refusal_policy(policy, @reason)

      config = CompletionConfig.new(recovery: Keyword.put(policy, :max_attempts, 2))
      assert {:error, error} = invoke(@gateway, @operation, config)
      assert error.resend_permission == @reason
      requests = GenServer.call(server, :requests)

      if error.wire_attempt == 0 do
        assert requests == []
      else
        [request] = requests
        assert_payload(request, @gateway, @operation)
        assert error.http_status == 504
        assert error.provider_request_id == "wire-request-73"
      end
    end
  end

  for phase <- [:request, :admission, :backoff],
      gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object] do
    @phase phase
    @gateway gateway
    @operation operation
    test "#{gateway} #{operation} real Req cancellation during #{phase} is authoritative and sends no retry" do
      response = if @phase == :request, do: :hold, else: response(503, "response-secret")

      server =
        start_supervised!({ScriptedCompletionServer, {self(), [response, response(200, "{}")]}})

      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()
      cancel = make_ref()
      supervisor = start_supervised!(Task.Supervisor)

      policy = [
        max_attempts: 2,
        cancel_ref: cancel,
        admission: fn context ->
          send(owner, {:waiting, context})
          if @phase == :admission, do: :pending, else: :allow
        end,
        observer: &send(owner, {:cancel_event, &1})
      ]

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          invoke(@gateway, @operation, CompletionConfig.new(recovery: policy))
        end)

      assert_receive {:wire_request, request}, 2000
      assert_payload(request, @gateway, @operation)
      if @phase == :admission, do: assert_receive({:waiting, _}, 2000)

      if @phase == :backoff,
        do: assert_receive({:cancel_event, %{type: :backoff_started}}, 2000)

      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert_cancelled_phase(@phase, error)
      assert error.wire_attempt == 1
      assert GenServer.call(server, :requests) == [request]
      assert_receive {:cancel_event, %{type: :cancelled}}
    end
  end

  defp assert_cancelled_phase(:request, error) do
    assert error.category == :cancellation
    assert error.reason == :cancelled
    assert CompletionError.cause(error) == :cancelled
  end

  defp assert_cancelled_phase(phase, error) when phase in [:admission, :backoff] do
    assert error.category == :http
    assert error.reason == :http_status
    assert error.http_status == 503
    assert error.resend_permission == :cancelled
    assert {:ok, %{status_code: 503, body: "response-secret"}} = CompletionError.cause(error)
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    @tag :dispatch_proof
    test "#{gateway} #{operation} cancellation inside retry worker guard retains only dispatched failure" do
      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(503, "response-secret"), :hold]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()
      cancel = make_ref()
      supervisor = start_supervised!(Task.Supervisor)
      guards = start_supervised!({Agent, fn -> 0 end})

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          caller = self()

          clock = fn ->
            if self() != caller do
              number = Agent.get_and_update(guards, fn n -> {n + 1, n + 1} end)

              if number == 2 do
                send(owner, {:dispatch_guard, self()})

                receive do
                  :release_guard -> :ok
                end
              end
            end

            0
          end

          config =
            CompletionConfig.new(
              recovery: [
                max_attempts: 3,
                deadline: 100_000,
                clock: clock,
                cancel_ref: cancel,
                admission: fn _ -> :allow end,
                base_delay: 0,
                sleeper: fn _ -> :ok end,
                observer: &send(owner, {:dispatch_event, &1})
              ]
            )

          invoke(@gateway, @operation, config)
        end)

      assert_receive {:wire_request, request}, 2000
      assert_payload(request, @gateway, @operation)
      assert_receive {:dispatch_guard, worker}, 2000
      monitor = Process.monitor(worker)
      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert GenServer.call(server, :requests) == [request]
      refute_received {:wire_request, _}
      assert error.provider == provider(@gateway)
      assert error.operation == @operation
      assert error.resend_permission == :cancelled
      assert error.category == :http
      assert error.http_status == 503
      assert error.provider_request_id == "wire-request-73"
      assert error.retry_after == {:delay_seconds, 11}
      assert {:ok, %{status_code: 503, body: "response-secret"}} = CompletionError.cause(error)
      assert error.wire_attempt == 1
      assert [failure] = error.history
      assert failure.logical_request_id == error.logical_request_id
      assert failure.attempt_id == error.attempt_id
      assert failure.wire_attempt == 1
      assert failure.http_status == 503

      events = drain_dispatch_events()

      assert Enum.map(events, & &1.type) == [
               :attempt_started,
               :attempt_failed,
               :admission_pending,
               :admission_allowed,
               :backoff_started,
               :retry_started,
               :cancelled
             ]

      assert_event_identity(events, error)

      assert Enum.at(events, 1).metadata.history == [failure]
      assert Enum.at(events, 5).metadata.next_attempt == 2
      assert List.last(events).metadata == CompletionError.safe_metadata(error)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    @tag :dispatch_accounting
    test "#{gateway} #{operation} cancellation inside initial worker guard has no wire lifecycle" do
      server = start_supervised!({ScriptedCompletionServer, {self(), [:hold]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()
      cancel = make_ref()
      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          caller = self()

          clock = fn ->
            if self() != caller do
              send(owner, {:initial_guard, self()})

              receive do
                :release_guard -> :ok
              end
            end

            0
          end

          config =
            CompletionConfig.new(
              recovery: [
                max_attempts: 3,
                deadline: 100_000,
                clock: clock,
                cancel_ref: cancel,
                observer: &send(owner, {:dispatch_event, &1})
              ]
            )

          invoke(@gateway, @operation, config)
        end)

      assert_receive {:initial_guard, worker}, 2000
      monitor = Process.monitor(worker)
      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert GenServer.call(server, :requests) == []
      refute_received {:wire_request, _}
      assert error.provider == provider(@gateway)
      assert error.operation == @operation
      assert error.category == :cancellation
      assert error.reason == :cancelled
      assert error.resend_permission == :cancelled
      assert error.wire_attempt == 0
      assert error.history == []
      assert CompletionError.cause(error) == :cancelled
      assert [%{type: :cancelled, metadata: metadata}] = drain_dispatch_events()
      assert metadata == CompletionError.safe_metadata(error)
      assert metadata.logical_request_id == error.logical_request_id
      assert metadata.attempt_id == error.attempt_id
      assert metadata.wire_attempt == 0
      assert metadata.history == []
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      dispatch <- [:initial, :retry] do
    @gateway gateway
    @operation operation
    @dispatch dispatch
    @tag :dispatch_accounting
    test "#{gateway} #{operation} cancellation after #{dispatch} server dispatch retains actual attempts" do
      responses = if @dispatch == :initial, do: [:hold], else: [response(503, "failed"), :hold]
      server = start_supervised!({ScriptedCompletionServer, {self(), responses}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()
      cancel = make_ref()
      supervisor = start_supervised!(Task.Supervisor)

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 3,
            cancel_ref: cancel,
            base_delay: 0,
            sleeper: fn _ -> :ok end,
            admission: fn _ -> :allow end,
            observer: &send(owner, {:dispatch_event, &1})
          ]
        )

      task =
        Task.Supervisor.async_nolink(supervisor, fn -> invoke(@gateway, @operation, config) end)

      assert_receive {:wire_request, first}, 2000
      assert_payload(first, @gateway, @operation)

      requests =
        if @dispatch == :retry do
          assert_receive {:wire_request, second}, 2000
          assert second == first
          [first, second]
        else
          [first]
        end

      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert GenServer.call(server, :requests) == requests
      refute_received {:wire_request, _}
      assert error.provider == provider(@gateway)
      assert error.operation == @operation
      assert error.category == :cancellation
      assert error.reason == :cancelled
      assert CompletionError.cause(error) == :cancelled
      events = drain_dispatch_events()
      assert_dispatched_cancellation(@dispatch, error, events)
    end
  end

  defp assert_dispatched_cancellation(:initial, error, events) do
    assert Enum.map(events, & &1.type) == [:attempt_started, :attempt_failed, :cancelled]
    assert error.wire_attempt == 1
    assert [failure] = error.history
    assert failure.category == :cancellation
    assert failure.reason == :cancelled
    assert failure.attempt_id == error.attempt_id
    assert failure.logical_request_id == error.logical_request_id
    assert failure.wire_attempt == 1

    assert_event_identity(events, error)

    assert Enum.at(events, 1).metadata.history == [failure]
    assert List.last(events).metadata == CompletionError.safe_metadata(error)
  end

  defp assert_dispatched_cancellation(:retry, error, events) do
    assert Enum.map(events, & &1.type) == [
             :attempt_started,
             :attempt_failed,
             :admission_pending,
             :admission_allowed,
             :backoff_started,
             :retry_started,
             :attempt_started,
             :attempt_failed,
             :cancelled
           ]

    assert error.wire_attempt == 2
    assert [first, cancelled] = error.history
    assert first.category == :http
    assert first.http_status == 503
    assert first.wire_attempt == 1
    assert cancelled.category == :cancellation
    assert cancelled.reason == :cancelled
    assert cancelled.wire_attempt == 2
    assert cancelled.attempt_id == error.attempt_id
    assert first.attempt_id != error.attempt_id

    for failure <- error.history,
        do: assert(failure.logical_request_id == error.logical_request_id)

    assert_event_identity(Enum.take(events, 6), first)
    assert_event_identity(Enum.drop(events, 6), cancelled)

    assert Enum.at(events, 1).metadata.history == [first]
    assert Enum.at(events, 5).metadata.next_attempt == 2
    assert Enum.at(events, 7).metadata.history == [first, cancelled]
    assert List.last(events).metadata == CompletionError.safe_metadata(error)
  end

  defp assert_event_identity(events, ids) do
    for event <- events do
      assert event.metadata.logical_request_id == ids.logical_request_id
      assert event.metadata.attempt_id == ids.attempt_id
      assert event.metadata.wire_attempt == ids.wire_attempt
    end
  end

  defp drain_dispatch_events do
    receive do
      {:dispatch_event, event} -> [event | drain_dispatch_events()]
    after
      0 -> []
    end
  end

  defp successful_body(Ollama, operation) do
    content = if operation == :complete, do: "done", else: ~s({"value":"done"})
    Jason.encode!(%{message: %{content: content}, done: true})
  end

  defp successful_body(_gateway, operation) do
    content = if operation == :complete, do: "done", else: ~s({"value":"done"})
    Jason.encode!(%{choices: [%{message: %{content: content}}]})
  end

  for gateway <- [OpenAI, Ollama, OMLX], caller <- [:broker, :session] do
    @gateway gateway
    @caller caller
    test "#{gateway} #{@caller} real Req recovers after exact tool result without tool replay" do
      tool = %Mojentic.TestSupport.CountingTool{owner: self()}

      arguments =
        if @gateway == Ollama, do: %{"value" => "tool-secret"}, else: ~s({"value":"tool-secret"})

      call = %{id: "call-17", type: "function", function: %{name: "count", arguments: arguments}}
      message = %{content: nil, tool_calls: [call]}

      body =
        if @gateway == Ollama,
          do: Jason.encode!(%{message: message}),
          else: Jason.encode!(%{choices: [%{message: message}]})

      responses = [
        response(200, body),
        response(503, "response-secret"),
        response(200, successful_body(@gateway, :complete))
      ]

      responses =
        if @caller == :session,
          do: [response(200, successful_body(@gateway, :complete)) | responses],
          else: responses

      server = start_supervised!({ScriptedCompletionServer, {self(), responses}})

      assert_receive {:server_port, port}
      configure(@gateway, port)
      broker = Broker.new("gpt-4o", @gateway)

      policy = [
        max_attempts: 2,
        base_delay: 0,
        admission: fn _ -> :allow end,
        sleeper: fn _ -> :ok end
      ]

      if @caller == :broker do
        assert {:ok, "done"} =
                 Broker.generate(
                   broker,
                   [Message.user("payload-secret")],
                   [tool],
                   CompletionConfig.new(recovery: policy, max_tool_iterations: 1)
                 )
      else
        session = ChatSession.new(broker, tools: [tool])
        assert {:ok, "done", session} = ChatSession.send(session, "earlier-secret", recovery: [])

        assert {:ok, "done", updated} =
                 ChatSession.send(session, "payload-secret", recovery: policy)

        assert updated.messages |> Enum.map(& &1.message) ==
                 Enum.map(session.messages, & &1.message) ++
                   [Message.user("payload-secret"), Message.assistant("done")]

        assert Enum.map(session.messages, & &1.message.role) == [:system, :user, :assistant]
      end

      assert_receive {:tool_executed, %{"value" => "tool-secret"}}
      refute_received {:tool_executed, _}
      requests = GenServer.call(server, :requests)
      [initial, failed, recovered] = tool_requests(requests, @caller)
      assert failed == recovered
      first = wire_payload(initial)
      retry = wire_payload(recovered)
      [assistant, result] = Enum.take(retry["messages"], -2)
      assert Enum.drop(retry["messages"], -2) == first["messages"]
      assert Map.delete(retry, "messages") == Map.delete(first, "messages")
      expected_call = if @gateway == Ollama, do: Map.delete(call, :id), else: call
      expected_call = Jason.decode!(Jason.encode!(expected_call))

      assert assistant ==
               Map.merge(
                 %{"role" => "assistant", "tool_calls" => [expected_call]},
                 if(@gateway == Ollama, do: %{"content" => ""}, else: %{})
               )

      expected = %{"role" => "tool", "content" => Jason.encode!("tool-result-secret")}

      assert result ==
               if(@gateway == Ollama,
                 do: Map.put(expected, "tool_calls", [expected_call]),
                 else: Map.put(expected, "tool_call_id", "call-17")
               )

      assert first["tools"] == [Jason.decode!(Jason.encode!(tool.__struct__.descriptor()))]
    end
  end

  test "real Req recovery does not replenish broker tool depth" do
    tool = %Mojentic.TestSupport.CountingTool{owner: self()}

    message = %{
      content: nil,
      tool_calls: [
        %{
          id: "call-17",
          type: "function",
          function: %{name: "count", arguments: ~s({"value":"tool-secret"})}
        }
      ]
    }

    body = Jason.encode!(%{choices: [%{message: message}]})

    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {self(), [response(200, body), response(503, "response-secret"), response(200, body)]}}
      )

    assert_receive {:server_port, port}
    configure(OpenAI, port)

    config =
      CompletionConfig.new(
        max_tool_iterations: 1,
        recovery: [max_attempts: 2, base_delay: 0, sleeper: fn _ -> :ok end]
      )

    assert {:error, :max_tool_iterations_exceeded} =
             Broker.generate(
               Broker.new("gpt-4o", OpenAI),
               [Message.user("payload-secret")],
               [tool],
               config
             )

    assert_receive {:tool_executed, %{"value" => "tool-secret"}}
    refute_received {:tool_executed, _}
    [_, failed, retried] = GenServer.call(server, :requests)
    assert failed == retried

    assert List.last(wire_payload(retried)["messages"]) == %{
             "role" => "tool",
             "content" => Jason.encode!("tool-result-secret"),
             "tool_call_id" => "call-17"
           }
  end

  defp tool_requests([setup, initial, failed, recovered], :session) do
    prior_messages = wire_payload(setup)["messages"]
    assert List.last(prior_messages) == %{"role" => "user", "content" => "earlier-secret"}

    assert wire_payload(initial)["messages"] ==
             prior_messages ++
               [
                 %{"role" => "assistant", "content" => "done"},
                 %{"role" => "user", "content" => "payload-secret"}
               ]

    [initial, failed, recovered]
  end

  defp tool_requests([initial, failed, recovered], :broker), do: [initial, failed, recovered]

  defp expected_retry_after("2"), do: %{kind: :delay_seconds, value: 2}

  defp expected_retry_after("Thu, 01 Jan 2026 00:00:03 GMT"),
    do: %{kind: :http_date, value: "2026-01-01T00:00:03Z"}

  defp expected_retry_after("Wed, 31 Dec 2025 23:59:00 GMT"),
    do: %{kind: :http_date, value: "2025-12-31T23:59:00Z"}

  defp expected_retry_after("garbage"), do: :invalid

  defp refusal_policy(policy, reason) when reason in [:retry_after_ceiling, :deadline],
    do: Keyword.put_new(policy, :admission, fn _ -> :allow end)

  defp refusal_policy(policy, _reason), do: policy

  defp wire_payload(request),
    do: request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    test "#{gateway} #{operation} real Req permanent failure does not retry under bounded recovery" do
      for status <- [400, 401, 403, 404, 422] do
        server =
          start_supervised!(
            {ScriptedCompletionServer, {self(), [response(status, "response-secret")]}},
            id: status
          )

        assert_receive {:server_port, port}
        configure(@gateway, port)

        config =
          CompletionConfig.new(
            recovery: [max_attempts: 3, admission: fn _ -> flunk("ineligible admission") end]
          )

        assert {:error, error} = invoke(@gateway, @operation, config)
        assert error.http_status == status
        assert error.provider_request_id == "wire-request-73"
        assert error.wire_attempt == 1
        [request] = GenServer.call(server, :requests)
        assert_payload(request, @gateway, @operation)
      end
    end

    test "#{gateway} #{operation} recovery deadline allows active generation to finish" do
      server = start_supervised!({ScriptedCompletionServer, {self(), [:hold]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      clock = start_supervised!({Agent, fn -> 0 end})
      supervisor = start_supervised!(Task.Supervisor)

      config =
        CompletionConfig.new(recovery: [deadline: 100, clock: fn -> Agent.get(clock, & &1) end])

      task =
        Task.Supervisor.async_nolink(supervisor, fn -> invoke(@gateway, @operation, config) end)

      assert_receive {:wire_request, request}, 2000
      assert_payload(request, @gateway, @operation)
      Agent.update(clock, fn _ -> 1000 end)
      GenServer.call(server, {:release, response(200, successful_body(@gateway, @operation))})
      assert {:ok, _} = Task.await(task, 2000)
      assert GenServer.call(server, :requests) == [request]
    end

    for phase <- [:admission, :backoff] do
      @phase phase
      test "#{gateway} #{operation} no resend at exact deadline after #{phase}" do
        server =
          start_supervised!(
            {ScriptedCompletionServer, {self(), [response(503, "response-secret")]}}
          )

        assert_receive {:server_port, port}
        configure(@gateway, port)
        clock = start_supervised!({Agent, fn -> 0 end})

        config =
          CompletionConfig.new(
            recovery: [
              max_attempts: 2,
              deadline: 20_000,
              clock: fn -> Agent.get(clock, & &1) end,
              admission: fn _ ->
                if @phase == :admission, do: Agent.update(clock, fn _ -> 20_000 end)
                :allow
              end,
              sleeper: fn _ -> Agent.update(clock, fn _ -> 20_000 end) end
            ]
          )

        assert {:error, error} = invoke(@gateway, @operation, config)
        assert error.resend_permission == :deadline
        assert error.wire_attempt == 1
        assert error.http_status == 503
        [request] = GenServer.call(server, :requests)
        assert_payload(request, @gateway, @operation)
      end
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object],
      decision <- [:allow, :reject] do
    @gateway gateway
    @operation operation
    @decision decision
    test "#{gateway} #{operation} real Req pending admission requires explicit #{decision}" do
      server =
        start_supervised!(
          {ScriptedCompletionServer,
           {self(),
            [
              response(503, "response-secret"),
              response(200, successful_body(@gateway, @operation))
            ]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)
      owner = self()
      supervisor = start_supervised!(Task.Supervisor)

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            sleeper: fn _ -> :ok end,
            admission: fn context ->
              send(owner, {:pending, context})
              :pending
            end
          ]
        )

      task =
        Task.Supervisor.async_nolink(supervisor, fn -> invoke(@gateway, @operation, config) end)

      assert_receive {:wire_request, first}, 2000
      assert_payload(first, @gateway, @operation)
      assert_receive {:pending, context}, 2000
      assert context.failure.http_status == 503
      assert context.failure.provider_request_id == "wire-request-73"
      assert context.failure.retry_after == %{kind: :delay_seconds, value: 11}
      assert context.previous_attempt_id == context.failure.attempt_id
      assert context.logical_request_id == context.failure.logical_request_id
      assert context.next_attempt == 2
      assert GenServer.call(server, :requests) == [first]
      send(context.reply_to, {:recovery_admission, context.ref, @decision})
      result = Task.await(task, 2000)

      if @decision == :allow do
        assert {:ok, _} = result
        assert GenServer.call(server, :requests) == [first, first]
      else
        assert {:error, error} = result
        assert error.resend_permission == :rejected
        assert error.http_status == 503
        assert error.history == [Map.delete(context.failure, :history)]
        assert error.wire_attempt == 1
        assert GenServer.call(server, :requests) == [first]
      end
    end
  end

  for phase <- [:admission, :backoff] do
    @phase phase
    test "real Req cancellation kills blocked #{phase} callback worker" do
      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(503, "response-secret")]}}
        )

      assert_receive {:server_port, port}
      configure(Ollama, port)
      owner = self()
      cancel = make_ref()

      blocked = fn _ ->
        send(owner, {:worker, self()})

        receive do
          :unused -> :ok
        end
      end

      policy = [
        max_attempts: 2,
        cancel_ref: cancel,
        admission: if(@phase == :admission, do: blocked, else: fn _ -> :allow end),
        sleeper: blocked
      ]

      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          invoke(Ollama, :complete, CompletionConfig.new(recovery: policy))
        end)

      assert_receive {:wire_request, request}, 2000
      assert_receive {:worker, worker}, 2000
      monitor = Process.monitor(worker)
      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert error.resend_permission == :cancelled
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert GenServer.call(server, :requests) == [request]
      assert_payload(request, Ollama, :complete)
    end
  end

  test "real Req jitter ceilings saturate without exponent overflow" do
    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {self(),
          [
            response(503, "response-secret")
            |> String.replace("Retry-After: 11", "Retry-After: invalid"),
            response(200, successful_body(OpenAI, :complete))
          ]}}
      )

    assert_receive {:server_port, port}
    configure(OpenAI, port)
    owner = self()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          base_delay: Integer.pow(2, 1024),
          delay_ceiling: 17,
          jitter: fn ceiling ->
            assert ceiling == 17
            ceiling
          end,
          sleeper: fn delay ->
            send(owner, {:delay, delay})
            :ok
          end
        ]
      )

    assert {:ok, _} = invoke(OpenAI, :complete, config)
    assert_receive {:delay, 17}
    [first, second] = GenServer.call(server, :requests)
    assert first == second
    assert_payload(first, OpenAI, :complete)
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation
    test "#{gateway} #{operation} recovery freezes legacy adaptation of history schema tools and controls" do
      body = successful_body(@gateway, @operation)

      server =
        start_supervised!(
          {ScriptedCompletionServer,
           {self(), [response(200, body), response(503, "response-secret"), response(200, body)]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)

      messages = [
        Message.system("system-secret"),
        Message.user("earlier-secret"),
        Message.assistant("reasoning-history-secret"),
        Message.user("payload-secret")
      ]

      config =
        CompletionConfig.new(
          temperature: 0.3,
          max_tokens: 27,
          num_ctx: 4192,
          top_p: 0.4,
          top_k: 8,
          reasoning_effort: :high
        )

      call = fn config ->
        if @operation == :complete do
          @gateway.complete(
            "gpt-4o",
            messages,
            [%Mojentic.TestSupport.CountingTool{owner: self()}],
            config
          )
        else
          @gateway.complete_object(
            "gpt-4o",
            messages,
            %{
              "type" => "object",
              "properties" => %{"value" => %{"type" => "string"}},
              "required" => ["value"]
            },
            config
          )
        end
      end

      assert {:ok, legacy} = call.(config)
      policy = [max_attempts: 2, admission: fn _ -> :allow end, sleeper: fn _ -> :ok end]
      assert {:ok, ^legacy} = call.(%{config | recovery: policy})
      [baseline, failed, recovered] = GenServer.call(server, :requests)
      assert failed == baseline
      assert recovered == baseline
      payload = wire_payload(baseline)
      assert payload["model"] == "gpt-4o"

      assert payload["messages"] ==
               Enum.map(messages, fn message ->
                 %{"role" => Atom.to_string(message.role), "content" => message.content}
               end)

      if @operation == :complete do
        assert payload["tools"] == [
                 Jason.decode!(Jason.encode!(Mojentic.TestSupport.CountingTool.descriptor()))
               ]
      else
        schema =
          if @gateway == Ollama,
            do: payload["format"],
            else: payload["response_format"]["json_schema"]["schema"]

        assert schema == %{
                 "type" => "object",
                 "properties" => %{"value" => %{"type" => "string"}},
                 "required" => ["value"]
               }
      end

      controls = if @gateway == Ollama, do: payload["options"], else: payload
      assert controls["temperature"] == 0.3
      assert controls[if(@gateway == Ollama, do: "num_predict", else: "max_tokens")] == 27
      assert controls["top_p"] == 0.4
      assert messages |> List.last() == Message.user("payload-secret")
    end
  end

  test "real Req monotonic budget begins at first failure and never resets on later failures" do
    transient =
      response(503, "response-secret") |> String.replace("Retry-After: 11", "Retry-After: 0")

    server =
      start_supervised!({ScriptedCompletionServer, {self(), [:hold, transient, transient]}})

    assert_receive {:server_port, port}
    configure(Ollama, port)
    clock = start_supervised!({Agent, fn -> 0 end})
    supervisor = start_supervised!(Task.Supervisor)

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 3,
          budget: 50,
          base_delay: 0,
          clock: fn -> Agent.get(clock, & &1) end,
          admission: fn context ->
            if context.next_attempt == 3, do: Agent.update(clock, fn _ -> 1050 end)
            :allow
          end,
          sleeper: fn _ -> Agent.update(clock, fn _ -> 1025 end) end
        ]
      )

    task = Task.Supervisor.async_nolink(supervisor, fn -> invoke(Ollama, :complete, config) end)
    assert_receive {:wire_request, first}, 2000
    Agent.update(clock, fn _ -> 1000 end)
    GenServer.call(server, {:release, transient})
    assert {:error, error} = Task.await(task, 2000)
    assert error.resend_permission == :deadline
    assert error.wire_attempt == 2
    assert Enum.map(error.history, & &1.http_status) == [503, 503]
    assert GenServer.call(server, :requests) == [first, first]
    assert_payload(first, Ollama, :complete)
  end

  test "real Req exponential full jitter doubles and saturates at the configured ceiling" do
    failure =
      response(503, "response-secret")
      |> String.replace("Retry-After: 11", "Retry-After: invalid")

    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {self(),
          List.duplicate(failure, 4) ++
            [response(200, successful_body(OpenAI, :complete))]}}
      )

    assert_receive {:server_port, port}
    configure(OpenAI, port)
    owner = self()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 5,
          base_delay: 10,
          delay_ceiling: 25,
          jitter: fn ceiling ->
            send(owner, {:ceiling, ceiling})
            div(ceiling, 2)
          end,
          sleeper: fn delay ->
            send(owner, {:delay, delay})
            :ok
          end
        ]
      )

    assert {:ok, _} = invoke(OpenAI, :complete, config)

    for {ceiling, delay} <- [{10, 5}, {20, 10}, {25, 12}, {25, 12}] do
      assert_receive {:ceiling, ^ceiling}
      assert_receive {:delay, ^delay}
    end

    [first | rest] = GenServer.call(server, :requests)
    assert rest == List.duplicate(first, 4)
    assert_payload(first, OpenAI, :complete)
  end

  for failure <- [:raise, :return] do
    @failure failure
    test "real Req sleeper #{failure} failure never enters safe errors history events or logs" do
      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(503, "response-secret")]}}
        )

      assert_receive {:server_port, port}
      configure(Ollama, port)
      owner = self()

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            admission: fn _ -> :allow end,
            sleeper: failing_sleeper(@failure),
            observer: &send(owner, {:sleeper_event, &1})
          ]
        )

      logs =
        capture_log(fn ->
          assert {:error, error} = invoke(Ollama, :complete, config)
          assert error.resend_permission == :backoff_failed
          assert error.http_status == 503
          assert error.provider_request_id == "wire-request-73"
          assert error.wire_attempt == 1

          for rendered <- [inspect(error), Jason.encode!(error), inspect(error.history)],
              do: refute(rendered =~ "callback-secret")
        end)

      refute logs =~ "callback-secret"

      events =
        for _ <- 1..6 do
          assert_receive {:sleeper_event, event}
          event
        end

      assert Enum.map(events, & &1.type) == [
               :attempt_started,
               :attempt_failed,
               :admission_pending,
               :admission_allowed,
               :backoff_started,
               :exhausted
             ]

      for secret <- ["callback-secret", "response-secret", "payload-secret", "credential-secret"],
          do: refute(inspect(events) =~ secret)

      [request] = GenServer.call(server, :requests)
      assert_payload(request, Ollama, :complete)
    end
  end

  defp failing_sleeper(:raise), do: fn _ -> raise "callback-secret" end
  defp failing_sleeper(:return), do: fn _ -> "callback-secret" end

  @tag :admission_proof
  test "ambiguous local 504 waits for explicit admission and preserves complete wire payload" do
    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {self(), [response(504, "response-secret"), response(504, "response-secret")]}}
      )

    assert_receive {:server_port, port}
    configure(Ollama, port)
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          base_delay: 0,
          sleeper: fn _ -> :ok end,
          admission: fn context ->
            send(owner, {:admission, context})
            :pending
          end,
          observer: &send(owner, {:recovery_event, &1})
        ]
      )

    task = Task.Supervisor.async_nolink(supervisor, fn -> invoke(Ollama, :complete, config) end)
    assert_receive {:wire_request, first}, 2000
    assert_payload(first, Ollama, :complete)
    assert_receive {:admission, context}, 2000
    assert context.failure.http_status == 504
    assert context.failure.provider_request_id == "wire-request-73"
    assert context.failure.retry_after == %{kind: :delay_seconds, value: 11}
    assert context.next_attempt == 2
    assert GenServer.call(server, :requests) == [first]
    send(context.reply_to, {:recovery_admission, context.ref, :allow})
    assert {:error, error} = Task.await(task, 2000)
    assert_receive {:wire_request, second}
    assert second == first
    assert error.wire_attempt == 2
    assert Enum.map(error.history, & &1.http_status) == [504, 504]
    assert Enum.uniq(Enum.map(error.history, & &1.attempt_id)) |> length() == 2

    assert Enum.uniq(Enum.map(error.history, & &1.logical_request_id)) == [
             error.logical_request_id
           ]

    assert GenServer.call(server, :requests) == [first, second]
  end

  defp response(status, body) do
    "HTTP/1.1 #{status} Result\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\nX-Request-ID: wire-request-73\r\nRetry-After: 11\r\n\r\n#{body}"
  end

  defp configure(gateway, port) do
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end

    System.put_env("OPENAI_API_KEY", "credential-secret")
    System.put_env("OMLX_API_KEY", "credential-secret")
  end
end
