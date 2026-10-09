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
      assert error.category == :cancellation or error.resend_permission == :cancelled
      assert error.wire_attempt == 1
      assert GenServer.call(server, :requests) == [request]
      assert_receive {:cancel_event, %{type: :cancelled}}
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
