defmodule Mojentic.LLM.CancellationSocketWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer

  @env_keys ~w(OPENAI_API_ENDPOINT OPENAI_API_KEY OLLAMA_HOST OMLX_HOST OMLX_API_KEY OPENAI_TIMEOUT OLLAMA_TIMEOUT OMLX_TIMEOUT)

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

  @tag :received_evidence
  test "blocked body capture retains observed semantic evidence before public delivery" do
    owner = self()

    body =
      "data: " <>
        Jason.encode!(%{
          choices: [
            %{
              delta: %{
                content: "payload-secret",
                reasoning_content: "reason-secret",
                tool_calls: [%{index: 0, function: %{name: "secret_tool", arguments: "{}"}}]
              }
            }
          ]
        }) <> "\n\n"

    response =
      "HTTP/1.1 200 OK\r\nContent-Length: 9999\r\nX-Request-Id: evidence-id\r\nX-Secret: credential-secret\r\n\r\n" <>
        body

    server = start_supervised!({ScriptedCompletionServer, {owner, [{:stream_hold, response}]}})
    assert_receive {:server_port, port}
    configure(OpenAI, port)
    cancel = make_ref()

    config =
      CompletionConfig.new(
        recovery: [
          cancel_ref: cancel,
          observer: &send(owner, {:socket_lifecycle, &1}),
          trace_observer: fn event ->
            send(owner, {:socket_trace, event})
            if event.type == :response_data, do: receive(do: (:release_capture -> :ok)), else: :ok
          end
        ]
      )

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn -> invoke(OpenAI, :events, config, owner) end)

    assert_receive {:wire_request, wire}, 2000
    assert_receive {:socket_lifecycle, %{type: :attempt_started, metadata: ids}}, 2000
    assert_receive {:socket_trace, %{type: :response_data, body: ^body, ids: trace_ids}}, 2000
    assert trace_ids == Map.take(ids, [:logical_request_id, :attempt_id, :wire_attempt])
    send(task.pid, {:cancel, cancel})
    assert {:error, error} = Task.await(task, 2000)
    assert error.http_status == 200
    assert error.progress.raw_bytes == byte_size(body)
    assert error.progress.headers_received

    assert error.progress.observed == %{
             content: true,
             reasoning: true,
             tool_fragments: 1,
             completed_tool_calls: 0
           }

    assert error.progress.delivered == %{
             content: false,
             reasoning: false,
             tool_fragments: 0,
             completed_tool_calls: 0
           }

    evidence = CompletionError.received_evidence(error)
    assert evidence.body == body
    assert {"x-secret", "credential-secret"} in evidence.headers
    assert evidence.status == 200
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
    assert GenServer.call(server, :requests) == [wire]
    assert_cancellation_error(error, ids, OpenAI, :events, :incomplete_response, true)
    refute_received {:public_content, _}
    refute inspect(error) =~ "payload-secret"
    refute Jason.encode!(error) =~ "credential-secret"
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      stage <- [:headers, :partial_body, :terminal_body] do
    @gateway gateway
    @operation operation
    @stage stage
    @tag :cancellation_evidence
    test "#{gateway} #{operation} cancellation at #{stage} retains received evidence before delivery" do
      assert_received_cancellation(@gateway, @operation, @stage)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:events, :legacy] do
    @gateway gateway
    @operation operation
    @tag :cancellation_evidence
    test "#{gateway} #{operation} observed reasoning content and tools survive blocked capture" do
      assert_received_cancellation(@gateway, @operation, :observed_body)
    end

    @tag :cancellation_evidence
    test "#{gateway} #{operation} paused consumer cancels a buffered terminal before success" do
      assert_paused_cancellation(@gateway, @operation)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], caller <- [:broker, :session] do
    @gateway gateway
    @caller caller
    @tag :cancellation_evidence
    test "#{gateway} #{caller} forwards cancellation evidence and prevents completed tools" do
      assert_paused_cancellation(@gateway, @caller)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      status <- [200, 503] do
    @gateway gateway
    @operation operation
    @status status
    @tag :cancellation_cause
    test "#{gateway} #{operation} HTTP #{status} retains the received native closed cause through cancellation" do
      owner = self()

      body = cause_body(@gateway, @operation)

      response =
        String.replace(evidence_response(body), "HTTP/1.1 200 OK", "HTTP/1.1 #{@status} Response")

      server =
        start_supervised!({ScriptedCompletionServer, {owner, [{:stream_half_close, response}]}})

      assert_receive {:server_port, port}
      configure(@gateway, port)
      cancel = make_ref()

      config =
        CompletionConfig.new(
          recovery: [
            cancel_ref: cancel,
            observer: &send(owner, {:socket_lifecycle, &1}),
            trace_observer: fn event ->
              send(owner, {:socket_trace, event})

              if event.type == :response_end and event.outcome == :failed,
                do: receive(do: (:release_capture -> :ok)),
                else: :ok
            end
          ]
        )

      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          invoke(@gateway, @operation, config, owner)
        end)

      assert_receive {:wire_request, wire}, 2000
      assert_receive {:socket_lifecycle, %{type: :attempt_started, metadata: started}}, 2000
      assert_receive {:socket_trace, %{type: :response_end, outcome: :failed, ids: ids}}, 2000
      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert %Mint.TransportError{reason: :closed} = CompletionError.cause(error)
      assert error.category == :cancellation
      assert error.http_status == @status
      assert error.progress.raw_bytes == byte_size(body)
      assert CompletionError.received_evidence(error).status == @status
      assert CompletionError.received_evidence(error).body == body
      assert ids == Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])
      assert CompletionError.received_evidence(error).ids == ids
      assert_cancellation_error(error, started, @gateway, @operation, :received_response, true)
      assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
      assert GenServer.call(server, :requests) == [wire]
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], caller <- [:broker, :session] do
    @gateway gateway
    @caller caller
    @tag :cancellation_evidence
    test "#{gateway} #{caller} ordinary cancellation keeps prior attempts and exact received evidence" do
      owner = self()
      body = evidence_body(@gateway, :complete, :terminal_body)
      rejected_body = "{\"error\":{\"code\":\"busy\"}}"

      rejected =
        "HTTP/1.1 503 Unavailable\r\nContent-Length: #{byte_size(rejected_body)}\r\n\r\n" <>
          rejected_body

      server =
        start_supervised!(
          {ScriptedCompletionServer, {owner, [rejected, {:stream_hold, evidence_response(body)}]}}
        )

      assert_receive {:server_port, port}
      configure(@gateway, port)
      cancel = make_ref()

      config =
        CompletionConfig.new(
          recovery: [
            cancel_ref: cancel,
            max_attempts: 3,
            base_delay: 0,
            admission: fn _ -> :allow end,
            observer: &send(owner, {:socket_lifecycle, &1}),
            trace_observer: fn event ->
              send(owner, {:socket_trace, event})

              if event.type == :response_data and event.body == body,
                do: receive(do: (:release_capture -> :ok)),
                else: :ok
            end
          ]
        )

      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          broker = Broker.new("gpt-4o", @gateway)
          forwarded_complete(broker, @caller, config)
        end)

      assert_receive {:wire_request, first}, 2000
      assert_receive {:wire_request, second}, 2000
      assert_receive {:socket_trace, %{type: :response_data, body: ^body, ids: ids}}, 2000
      send(task.pid, {:cancel, cancel})
      assert {:error, error} = Task.await(task, 2000)
      assert_received_error(error, ids, body, expected_observed(:complete, :terminal_body))
      assert [previous, cancelled] = error.history
      assert previous.http_status == 503
      assert previous.category == :http
      assert previous.wire_attempt == 1
      assert cancelled.wire_attempt == 2
      assert previous.logical_request_id == error.logical_request_id
      refute previous.attempt_id == error.attempt_id
      assert Map.take(cancelled, Map.keys(ids)) == ids
      lifecycle = drain_lifecycle([])

      assert Enum.map(lifecycle, & &1.type) == [
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

      assert List.last(lifecycle).metadata == CompletionError.safe_metadata(error)
      starts = Enum.filter(lifecycle, &(&1.type == :attempt_started))
      assert Map.take(hd(starts).metadata, Map.keys(ids)) == Map.take(previous, Map.keys(ids))
      assert Map.take(List.last(starts).metadata, Map.keys(ids)) == ids
      traces = drain_traces([])
      assert Enum.all?(traces, &(&1.ids.logical_request_id == ids.logical_request_id))
      assert Enum.all?(Enum.filter(traces, &(&1.ids.wire_attempt == 2)), &(&1.ids == ids))
      assert GenServer.call(server, :requests) == [first, second]
      assert first == second
      assert GenServer.call(server, {:peer_state, second}) == {:error, :closed}
      refute_received {:tool_executed, _}
    end
  end

  defp drain_lifecycle(acc) do
    receive do
      {:socket_lifecycle, event} -> drain_lifecycle([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  for mode <- [:legacy, :events] do
    @mode mode
    @tag :cancellation_eof
    test "Ollama #{@mode} cancellation at complete EOF hook retains final undelivered frame" do
      assert_eof_cancellation(@mode)
    end
  end

  defp assert_eof_cancellation(mode) do
    owner = self()

    body =
      Jason.encode!(%{
        message: %{content: "payload-secret", thinking: "reason-secret"},
        done: true,
        done_reason: "stop"
      })

    response =
      String.replace(
        evidence_response(body),
        "Content-Length: 9999",
        "Content-Length: #{byte_size(body)}"
      )

    server = start_supervised!({ScriptedCompletionServer, {owner, [{:stream_hold, response}]}})
    assert_receive {:server_port, port}
    configure(Ollama, port)
    cancel = make_ref()

    config =
      CompletionConfig.new(
        recovery: [
          cancel_ref: cancel,
          observer: &send(owner, {:socket_lifecycle, &1}),
          trace_observer: fn event ->
            send(owner, {:socket_trace, event})

            if event.type == :response_end and event.outcome == :complete,
              do: receive(do: (:release_capture -> :ok)),
              else: :ok
          end
        ]
      )

    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> invoke(Ollama, mode, config, owner) end)
    assert_receive {:wire_request, wire}, 2000
    assert_receive {:socket_lifecycle, %{type: :attempt_started, metadata: started}}, 2000
    assert_receive {:socket_trace, %{type: :response_end, outcome: :complete, ids: ids}}, 2000
    send(task.pid, {:cancel, cancel})
    assert {:error, error} = Task.await(task, 2000)

    assert error.progress.observed == %{
             content: true,
             reasoning: true,
             tool_fragments: 0,
             completed_tool_calls: 0
           }

    assert error.progress.delivered == empty_semantic()
    assert error.progress.raw_bytes == byte_size(body)
    evidence = CompletionError.received_evidence(error)
    assert evidence.body == body
    assert evidence.status == 200
    assert {"content-length", Integer.to_string(byte_size(body))} in evidence.headers
    assert evidence.ids == ids
    assert ids == Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])
    assert_cancellation_error(error, started, Ollama, mode, :incomplete_response, true)
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
    assert GenServer.call(server, :requests) == [wire]
    refute_received {:public_content, _}
  end

  defp cause_body(Ollama, operation) when operation in [:events, :legacy],
    do: "{\"message\":{},\"done\":false}\n"

  defp cause_body(gateway, operation), do: evidence_body(gateway, operation, :partial_body)

  defp forwarded_complete(broker, :broker, config),
    do: Broker.generate(broker, [Message.user("payload-secret")], nil, config)

  defp forwarded_complete(broker, :session, config),
    do: ChatSession.send(ChatSession.new(broker), "payload-secret", recovery: config.recovery)

  defp assert_received_cancellation(gateway, operation, stage) do
    owner = self()
    body = evidence_body(gateway, operation, stage)
    response = evidence_response(body)
    server = start_supervised!({ScriptedCompletionServer, {owner, [{:stream_hold, response}]}})
    assert_receive {:server_port, port}
    configure(gateway, port)
    cancel = make_ref()
    blocked_type = if stage == :headers, do: :response_headers, else: :response_data

    config =
      CompletionConfig.new(
        recovery: [
          cancel_ref: cancel,
          max_attempts: 3,
          observer: &send(owner, {:socket_lifecycle, &1}),
          trace_observer: fn event ->
            send(owner, {:socket_trace, event})
            if event.type == blocked_type, do: receive(do: (:release_capture -> :ok)), else: :ok
          end
        ]
      )

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn -> invoke(gateway, operation, config, owner) end)

    assert_receive {:wire_request, wire}, 2000
    assert_request(wire, gateway, operation)
    assert_receive {:socket_lifecycle, %{type: :attempt_started, metadata: started}}, 2000
    assert_receive {:socket_trace, %{type: :request} = request_trace}, 2000
    assert_trace_request(request_trace, wire, started)
    assert_receive {:socket_trace, %{type: ^blocked_type, ids: ids} = blocked}, 2000
    assert ids == Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])
    if blocked_type == :response_data, do: assert(blocked.body == body)
    send(task.pid, {:cancel, cancel})
    assert {:error, error} = Task.await(task, 2000)
    received_body = if stage == :headers, do: "", else: body
    expected = expected_observed(operation, stage)
    assert_received_error(error, ids, received_body, expected)

    evidence_stage =
      if stage == :observed_body, do: :incomplete_response, else: :received_response

    assert_cancellation_error(error, started, gateway, operation, evidence_stage, true)
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
    assert GenServer.call(server, :requests) == [wire]
    refute_received {:public_content, _}
    refute_received {:tool_executed, _}
  end

  defp assert_paused_cancellation(gateway, caller) do
    owner = self()

    body =
      paused_body(gateway, caller) <>
        evidence_body(gateway, :legacy, :terminal_body)

    server =
      start_supervised!(
        {ScriptedCompletionServer, {owner, [{:stream_hold, evidence_response(body)}]}}
      )

    assert_receive {:server_port, port}
    configure(gateway, port)
    cancel = make_ref()

    config =
      CompletionConfig.new(
        recovery: [
          cancel_ref: cancel,
          max_attempts: 3,
          observer: fn event ->
            send(owner, {:socket_lifecycle, event})
            if event.type == :attempt_started, do: send(owner, {:coordinator, self()})
          end,
          trace_observer: fn event ->
            send(owner, {:socket_trace, event})
            :ok
          end
        ]
      )

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        stream = forwarded_stream(gateway, caller, config, owner)

        Enum.map(stream, fn event ->
          if event == {:content, "payload-secret"} or event == "payload-secret" do
            send(owner, {:paused, event})

            receive do
              :resume_consumer -> :ok
            end
          end

          event
        end)
      end)

    assert_receive {:wire_request, wire}, 2000
    assert_receive {:socket_lifecycle, %{type: :attempt_started, metadata: started}}, 2000
    assert_receive {:coordinator, coordinator}, 2000
    assert_receive {:paused, _}, 2000
    send(coordinator, {:cancel, cancel})
    # Cancellation and local closure happen while the consumer remains paused.
    assert_receive {:socket_lifecycle, %{type: :attempt_failed, metadata: failed}}, 2000
    assert_receive {:socket_lifecycle, %{type: :cancelled, metadata: stopped}}, 2000
    assert failed == stopped
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
    refute_received {:socket_lifecycle, _}
    send(task.pid, :resume_consumer)
    events = Task.await(task, 2000)
    assert {:error, error} = List.last(events)
    assert_paused_result(error, events, failed, started, server, wire, body, caller)
  end

  defp assert_paused_result(error, events, failed, started, server, wire, body, caller) do
    assert failed == CompletionError.safe_metadata(error)
    ids = Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])
    assert_received_error(error, ids, body, paused_observed(caller), false)
    assert error.progress.delivered.content
    assert error.progress.delivered.reasoning == (caller != :events)
    assert error.progress.delivered.completed_tool_calls == 0
    assert [history] = error.history
    assert Map.take(history, Map.keys(ids)) == ids
    assert GenServer.call(server, :requests) == [wire]
    refute Enum.any?(events, &match?({:completed, _}, &1))
    refute_received {:tool_executed, _}

    if caller == :session do
      assert_receive {:session_handle, handle, original}
      assert ChatSession.finalize_stream(handle) == {:error, error}
      assert ChatSession.messages(elem(handle, 0)) == original
    end

    traces = drain_traces([])
    assert Enum.any?(traces, &(&1.type == :response_data and &1.body == body))
    assert Enum.all?(traces, &(&1.ids == ids))
  end

  defp paused_body(gateway, :events) do
    message = %{
      content: "payload-secret",
      reasoning_content: "reason-secret",
      thinking: "reason-secret"
    }

    if gateway == Ollama,
      do: Jason.encode!(%{message: message, done: false}) <> "\n",
      else: "data: " <> Jason.encode!(%{choices: [%{delta: message}]}) <> "\n\n"
  end

  defp paused_body(gateway, _caller), do: evidence_body(gateway, :legacy, :observed_body)

  defp paused_observed(:events),
    do: %{content: true, reasoning: true, tool_fragments: 0, completed_tool_calls: 0}

  defp paused_observed(_),
    do: %{expected_observed(:legacy, :observed_body) | completed_tool_calls: 1}

  defp forwarded_stream(gateway, caller, config, owner) do
    tool = %Mojentic.TestSupport.CountingTool{owner: owner}
    broker = Broker.new("gpt-4o", gateway)

    case caller do
      :events ->
        gateway.complete_stream_events("gpt-4o", [Message.user("payload-secret")], config)

      :legacy ->
        gateway.complete_stream("gpt-4o", [Message.user("payload-secret")], [tool], config)

      :broker ->
        Broker.generate_stream(broker, [Message.user("payload-secret")], [tool], config)

      :session ->
        session = ChatSession.new(broker, tools: [tool])

        {:ok, stream, handle} =
          ChatSession.send_stream(session, "payload-secret", recovery: config.recovery)

        send(owner, {:session_handle, handle, ChatSession.messages(elem(handle, 0))})
        stream
    end
  end

  defp assert_received_error(error, ids, body, observed, undelivered \\ true) do
    assert error.category == :cancellation
    assert error.http_status == 200
    assert error.provider_request_id == "evidence-id"
    assert error.retry_after == {:delay_seconds, 4}
    assert error.progress.headers_received
    assert error.progress.raw_bytes == byte_size(body)
    assert error.progress.observed == observed
    if undelivered, do: assert(error.progress.delivered == empty_semantic())
    evidence = CompletionError.received_evidence(error)

    assert evidence == %{
             status: 200,
             body: body,
             ids: ids,
             headers: [
               {"content-length", "9999"},
               {"retry-after", "4"},
               {"x-request-id", "evidence-id"},
               {"x-secret", "credential-secret"}
             ]
           }

    assert CompletionError.cause(error) == :cancelled
    assert Map.take(CompletionError.safe_metadata(error), Map.keys(ids)) == ids

    for secret <- ["payload-secret", "reason-secret", "credential-secret", "secret-argument"] do
      refute inspect(error) =~ secret
      refute Jason.encode!(error) =~ secret
    end
  end

  defp drain_traces(acc) do
    receive do
      {:socket_trace, trace} -> drain_traces([trace | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp evidence_response(body),
    do:
      "HTTP/1.1 200 OK\r\nContent-Length: 9999\r\nRetry-After: 4\r\nX-Request-Id: evidence-id\r\nX-Secret: credential-secret\r\n\r\n" <>
        body

  defp empty_semantic,
    do: %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

  defp expected_observed(operation, :observed_body) when operation in [:legacy, :events],
    do: %{content: true, reasoning: true, tool_fragments: 1, completed_tool_calls: 0}

  defp expected_observed(operation, :terminal_body)
       when operation in [:complete, :complete_object],
       do: %{content: true, reasoning: true, tool_fragments: 0, completed_tool_calls: 0}

  defp expected_observed(_, _), do: empty_semantic()

  defp evidence_body(_gateway, _operation, :headers), do: ""

  defp evidence_body(_gateway, operation, :partial_body)
       when operation in [:complete, :complete_object],
       do: "{\"message\":{\"content\":\"partial"

  defp evidence_body(_gateway, operation, :terminal_body)
       when operation in [:complete, :complete_object],
       do: Jason.encode!(%{message: %{content: "payload-secret", thinking: "reason-secret"}})

  defp evidence_body(Ollama, _operation, :partial_body), do: ":keepalive\n"
  defp evidence_body(_gateway, _operation, :partial_body), do: ":keepalive\n\n"

  defp evidence_body(Ollama, _operation, :terminal_body),
    do: Jason.encode!(%{message: %{content: ""}, done: true}) <> "\n"

  defp evidence_body(_gateway, _operation, :terminal_body),
    do:
      "data: " <>
        Jason.encode!(%{choices: [%{delta: %{}, finish_reason: "stop"}]}) <>
        "\n\ndata: [DONE]\n\n"

  defp evidence_body(gateway, _operation, :observed_body) do
    message = %{
      content: "payload-secret",
      reasoning_content: "reason-secret",
      thinking: "reason-secret",
      tool_calls: [
        %{
          index: 0,
          id: "call-secret",
          function: %{name: "count", arguments: "{\"value\":\"secret-argument\"}"}
        }
      ]
    }

    if gateway == Ollama,
      do: Jason.encode!(%{message: message, done: false}) <> "\n",
      else: "data: " <> Jason.encode!(%{choices: [%{delta: message}]}) <> "\n\n"
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :complete_object, :events, :legacy],
      tracing <- [false, true],
      stage <- [:before_headers, :incomplete_response] do
    @gateway gateway
    @operation operation
    @tracing tracing
    @stage stage
    @tag :cancellation_socket
    test "#{gateway} #{operation} tracing #{tracing} #{@stage} closes correlated peer before fixture release" do
      assert_socket_cancellation(@gateway, @operation, @tracing, @stage)
    end
  end

  defp assert_socket_cancellation(gateway, operation, tracing, stage) do
    owner = self()
    partial = partial_response(gateway, operation)
    response = "HTTP/1.1 200 OK\r\nContent-Length: 9999\r\n\r\n" <> partial
    script = if stage == :before_headers, do: :hold, else: {:stream_hold, response}
    server = start_supervised!({ScriptedCompletionServer, {owner, [script]}})
    assert_receive {:server_port, port}
    configure(gateway, port)
    cancel = make_ref()

    recovery = [
      max_attempts: 3,
      cancel_ref: cancel,
      observer: &send(owner, {:socket_lifecycle, &1}),
      admission: fn _ ->
        send(owner, :unexpected_admission)
        :allow
      end
    ]

    recovery =
      if tracing do
        Keyword.put(recovery, :trace_observer, fn event ->
          send(owner, {:socket_trace, event})
          :ok
        end)
      else
        recovery
      end

    config = CompletionConfig.new(recovery: recovery)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        invoke(gateway, operation, config, owner)
      end)

    assert_receive {:wire_request, wire}, 2000
    assert_request(wire, gateway, operation)
    assert_receive {:socket_lifecycle, %{type: :attempt_started, metadata: started}}, 2000
    assert UUID.info!(started.logical_request_id)[:version] == 4
    assert UUID.info!(started.attempt_id)[:version] == 4
    refute started.logical_request_id == started.attempt_id
    assert started.wire_attempt == 1

    if tracing do
      assert_receive {:socket_trace, %{type: :request} = trace}, 2000
      assert_trace_request(trace, wire, started)
    end

    assert_incomplete_response(stage, tracing, operation, wire, {response, partial}, started)

    # A live peer on these exact bytes is the negative control in every case.
    # The fixture does not release or close either held response.
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :timeout}
    cancelled_at = System.monotonic_time(:millisecond)
    send(task.pid, {:cancel, cancel})
    assert {:error, error} = Task.await(task, 2000)
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
    assert System.monotonic_time(:millisecond) - cancelled_at < 2000
    assert_cancellation_error(error, started, gateway, operation, stage, tracing)

    # The listener and held socket remain owned by the running fixture here.
    # Observe the retry window before inspecting all recorded request bytes.
    refute_receive {:wire_request, _}, 100
    assert GenServer.call(server, :requests) == [wire]
  end

  defp assert_incomplete_response(stage, tracing, operation, wire, {response, partial}, started) do
    if stage == :incomplete_response do
      assert_receive {:held_response_sent, ^wire, ^response}, 2000

      if tracing do
        assert_receive {:socket_trace, %{type: :response_headers, status: 200, ids: header_ids}},
                       2000

        assert header_ids == Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])

        assert_receive {:socket_trace, %{type: :response_data, body: ^partial, ids: ^header_ids}},
                       2000
      end

      if operation in [:events, :legacy] do
        assert_receive {:public_content, "partial"}, 2000
      end
    end
  end

  defp assert_cancellation_error(error, started, gateway, operation, stage, tracing) do
    assert error.category == :cancellation

    expected_reason =
      if stage == :incomplete_response and operation in [:events, :legacy],
        do: :stream_interrupted,
        else: :cancelled

    assert error.reason == expected_reason
    assert error.resend_permission == :not_granted
    assert error.provider == provider(gateway)
    assert error.operation == operation(operation)
    assert error.logical_request_id == started.logical_request_id
    assert error.attempt_id == started.attempt_id
    assert error.wire_attempt == started.wire_attempt
    assert [failure] = error.history
    assert failure.logical_request_id == error.logical_request_id
    assert failure.attempt_id == error.attempt_id
    assert failure.wire_attempt == error.wire_attempt
    assert failure.category == :cancellation
    assert failure.reason == expected_reason
    assert_receive {:socket_lifecycle, %{type: :attempt_failed, metadata: failed}}, 2000
    assert_receive {:socket_lifecycle, %{type: :cancelled, metadata: stopped}}, 2000
    assert failed == CompletionError.safe_metadata(error)
    assert stopped == failed
    refute_received {:socket_lifecycle, _}
    refute_received :unexpected_admission

    unless tracing, do: refute_received({:socket_trace, _})

    if stage == :before_headers do
      refute_received {:socket_trace, %{type: :response_headers}}
      refute_received {:public_content, _}
    end
  end

  defp invoke(gateway, :complete, config, _owner),
    do: gateway.complete("gpt-4o", [Message.user("payload-secret")], [], config)

  defp invoke(gateway, :complete_object, config, _owner),
    do:
      gateway.complete_object(
        "gpt-4o",
        [Message.user("payload-secret")],
        %{"type" => "object"},
        config
      )

  defp invoke(gateway, mode, config, owner) do
    stream =
      if mode == :events,
        do: gateway.complete_stream_events("gpt-4o", [Message.user("payload-secret")], config),
        else: gateway.complete_stream("gpt-4o", [Message.user("payload-secret")], [], config)

    results =
      Enum.map(stream, fn item ->
        case item do
          {:content, content} -> send(owner, {:public_content, content})
          _ -> :ok
        end

        item
      end)

    assert {:error, _} = List.last(results)
    List.last(results)
  end

  defp assert_request(wire, gateway, operation) do
    [headers, body] = String.split(wire, "\r\n\r\n", parts: 2)
    path = if gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions"
    assert headers =~ "POST #{path} HTTP/1.1"
    assert headers =~ "content-length: #{byte_size(body)}"
    payload = Jason.decode!(body)
    assert payload["model"] == "gpt-4o"
    assert payload["messages"] == [%{"role" => "user", "content" => "payload-secret"}]
    assert payload["stream"] == true == operation in [:events, :legacy]

    if operation == :complete_object do
      if gateway == Ollama do
        assert payload["format"] == %{"type" => "object"}
      else
        assert payload["response_format"]["json_schema"]["schema"] == %{"type" => "object"}
      end
    end
  end

  defp assert_trace_request(trace, wire, started) do
    [headers, body] = String.split(wire, "\r\n\r\n", parts: 2)
    assert trace.body == body

    received_headers =
      for line <- tl(String.split(headers, "\r\n")) do
        [key, value] = String.split(line, ": ", parts: 2)
        {String.downcase(key), value}
      end

    for {key, value} <- trace.headers do
      assert {String.downcase(key), value} in received_headers
    end

    assert trace.ids == Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt])
  end

  defp partial_response(Ollama, operation) when operation in [:events, :legacy],
    do: Jason.encode!(%{message: %{content: "partial"}, done: false}) <> "\n"

  defp partial_response(_gateway, operation) when operation in [:events, :legacy],
    do: "data: " <> Jason.encode!(%{choices: [%{delta: %{content: "partial"}}]}) <> "\n\n"

  defp partial_response(_gateway, _operation), do: "partial"
  defp operation(:events), do: :complete_stream_events
  defp operation(:legacy), do: :complete_stream
  defp operation(mode), do: mode
  defp provider(OpenAI), do: :openai
  defp provider(Ollama), do: :ollama
  defp provider(OMLX), do: :omlx

  defp configure(gateway, port) do
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end

    System.put_env("OPENAI_API_KEY", "credential-secret")
    System.put_env("OMLX_API_KEY", "credential-secret")

    for key <- ~w(OPENAI_TIMEOUT OLLAMA_TIMEOUT OMLX_TIMEOUT),
        do: System.put_env(key, "10000")
  end
end
