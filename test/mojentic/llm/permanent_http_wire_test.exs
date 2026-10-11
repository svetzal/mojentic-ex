defmodule Mojentic.LLM.PermanentHTTPWireTest do
  use ExUnit.Case, async: false
  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer

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

  @tag :permanent_status_proof
  test "explicitly selected truncated 403 cannot reach admission through OpenAI" do
    owner = self()
    body = "permanent-error-secret-π"

    broken =
      String.replace(
        response(403, body),
        "Content-Length: #{byte_size(body)}",
        "Content-Length: 999"
      )

    server = start_supervised!({ScriptedCompletionServer, {owner, [broken]}})
    assert_receive {:server_port, port}
    configure(OpenAI, port)

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 3,
          retryable_categories: [:http, :transport],
          retryable_statuses: [400, 401, 403, 503],
          admission: fn _ -> flunk("permanent HTTP failure reached admission") end,
          sleeper: fn _ -> flunk("permanent HTTP failure reached backoff") end,
          observer: &send(owner, {:permanent_event, &1}),
          trace_observer: fn event ->
            send(owner, {:permanent_trace, event})
            :ok
          end
        ]
      )

    assert {:error, error} =
             OpenAI.complete("gpt-4o", [Message.user("payload-secret")], [], config)

    assert error.http_status == 403
    refute error.retry_eligible
    assert error.progress.raw_bytes == byte_size(body)
    assert CompletionError.received_evidence(error).body == body

    assert CompletionError.cause(error) ==
             %Finch.TransportError{reason: :closed, source: %Mint.TransportError{reason: :closed}}

    assert_receive {:wire_request, wire}
    assert GenServer.call(server, :requests) == [wire]
    assert_receive {:permanent_event, %{type: :attempt_started, metadata: started}}
    assert_receive {:permanent_event, %{type: :attempt_failed, metadata: failed}}
    assert_receive {:permanent_event, %{type: :exhausted}}
    assert [history] = error.history
    assert history == Map.delete(failed, :history)
    assert started.attempt_id == error.attempt_id
    assert started.logical_request_id == error.logical_request_id
    assert_permanent_trace(true, wire, started, 403, body)

    for safe <- [inspect(error), Jason.encode!(error), inspect(failed)] do
      refute safe =~ "secret"
    end

    refute_received {:permanent_event, _}
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [
        :complete,
        :complete_object,
        :events,
        :legacy,
        :broker,
        :broker_object,
        :session,
        :broker_stream,
        :broker_events,
        :session_stream
      ],
      status <- [400, 401, 403],
      body_mode <- [:complete, :closed, :timeout],
      tracing <- [false, true] do
    @gateway gateway
    @operation operation
    @status status
    @body_mode body_mode
    @tracing tracing
    @tag :permanent_status_matrix
    test "#{gateway} #{operation} selected #{status} #{body_mode} tracing #{tracing} remains permanent" do
      assert_permanent(@gateway, @operation, @status, @body_mode, @tracing)
    end
  end

  defp assert_permanent(gateway, operation, status, body_mode, tracing) do
    owner = self()
    body = "permanent-error-secret-π"
    response = response(status, body)
    broken = String.replace(response, "Content-Length: #{byte_size(body)}", "Content-Length: 999")

    scripted =
      case body_mode do
        :complete -> response
        :closed -> broken
        :timeout -> {:stream_hold, broken}
      end

    server = start_supervised!({ScriptedCompletionServer, {owner, [scripted]}})
    assert_receive {:server_port, port}
    configure(gateway, port)

    for key <- ["OPENAI_TIMEOUT", "OLLAMA_TIMEOUT", "OMLX_TIMEOUT"],
        do: System.put_env(key, "150")

    recovery = permanent_recovery(owner, tracing)
    assert {:error, error} = invoke(gateway, operation, CompletionConfig.new(recovery: recovery))
    assert_permanent_error(error, status, body, body_mode)
    assert_receive {:wire_request, wire}
    assert GenServer.call(server, :requests) == [wire]
    {started, failed} = assert_permanent_lifecycle(error)
    assert_permanent_payload(gateway, operation, wire)
    assert_permanent_trace(tracing, wire, started, status, body)

    for safe <- [inspect(error), Jason.encode!(error), inspect(failed), Jason.encode!(failed)] do
      refute safe =~ "secret"
      refute safe =~ "credential"
    end

    refute_received {:forbidden_admission, _}
    refute_received {:forbidden_backoff, _}
    refute_received {:permanent_event, _}
  end

  defp assert_permanent_lifecycle(error) do
    assert_receive {:permanent_event, %{type: :attempt_started, metadata: started}}
    assert_receive {:permanent_event, %{type: :attempt_failed, metadata: failed}}
    assert_receive {:permanent_event, %{type: :exhausted, metadata: exhausted}}
    assert [history] = error.history
    assert history == Map.delete(failed, :history)
    assert exhausted == failed
    assert started.attempt_id == error.attempt_id
    assert started.logical_request_id == error.logical_request_id
    assert started.wire_attempt == 1
    {started, failed}
  end

  defp permanent_recovery(owner, tracing) do
    recovery = [
      max_attempts: 3,
      retryable_categories: [:http, :transport],
      retryable_statuses: [400, 401, 403, 503],
      admission: fn context ->
        send(owner, {:forbidden_admission, context})
        :allow
      end,
      sleeper: fn delay ->
        send(owner, {:forbidden_backoff, delay})
        :ok
      end,
      observer: &send(owner, {:permanent_event, &1})
    ]

    recovery =
      if tracing,
        do:
          Keyword.put(recovery, :trace_observer, fn event ->
            send(owner, {:permanent_trace, event})
            :ok
          end),
        else: recovery

    recovery
  end

  defp assert_permanent_payload(gateway, operation, wire) do
    expected =
      if operation in [:session, :session_stream] do
        session = ChatSession.new(Broker.new("gpt-4o", gateway))

        Enum.map(session.messages, fn sized ->
          %{"role" => Atom.to_string(sized.message.role), "content" => sized.message.content}
        end) ++ [%{"role" => "user", "content" => "payload-secret"}]
      else
        [%{"role" => "user", "content" => "payload-secret"}]
      end

    [_, body] = String.split(wire, "\r\n\r\n", parts: 2)
    assert Jason.decode!(body)["messages"] == expected
  end

  defp assert_permanent_error(error, status, body, body_mode) do
    assert error.category == :http
    assert error.http_status == status
    refute error.retry_eligible
    assert error.reason == :http_status
    assert error.resend_permission == :not_granted
    assert error.wire_attempt == 1
    assert error.provider_request_id == "wire-request-73"
    assert error.retry_after == {:delay_seconds, 11}
    assert error.progress.headers_received
    assert error.progress.raw_bytes == byte_size(body)
    evidence = CompletionError.received_evidence(error)
    assert evidence.body == body
    assert evidence.status == status
    assert evidence.ids == Map.take(error, [:logical_request_id, :attempt_id, :wire_attempt])
    assert {"x-request-id", "wire-request-73"} in evidence.headers
    assert {"retry-after", "11"} in evidence.headers
    cause = CompletionError.cause(error)

    case body_mode do
      :complete -> assert cause != nil
      :closed -> assert_body_read_cause(cause, :closed)
      :timeout -> assert_body_read_cause(cause, :timeout)
    end
  end

  defp assert_body_read_cause(%{reason: reason}, expected), do: assert(reason == expected)
  defp assert_body_read_cause(reason, expected), do: assert(reason == expected)

  defp assert_permanent_trace(false, _wire, _started, _status, _body),
    do: refute_received({:permanent_trace, _})

  defp assert_permanent_trace(true, wire, started, status, body) do
    assert_receive {:permanent_trace, %{type: :request} = request}
    [_, request_body] = String.split(wire, "\r\n\r\n", parts: 2)

    assert_exact_dispatched_request(
      request,
      wire,
      started,
      Jason.decode!(request_body)["messages"]
    )

    ids = request.ids

    assert_receive {:permanent_trace,
                    %{type: :response_headers, status: ^status, headers: headers, ids: ^ids}}

    assert {"x-request-id", "wire-request-73"} in headers
    assert_receive {:permanent_trace, %{type: :response_data, body: ^body, ids: ^ids}}

    assert_receive {:permanent_trace,
                    %{type: :response_end, outcome: :failed, evidence: :available, ids: ^ids}}

    refute_received {:permanent_trace, _}
  end

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

  defp invoke(gateway, :broker, config),
    do:
      Broker.generate(Broker.new("gpt-4o", gateway), [Message.user("payload-secret")], [], config)

  defp invoke(gateway, :broker_object, config),
    do:
      Broker.generate_object(
        Broker.new("gpt-4o", gateway),
        [Message.user("payload-secret")],
        %{"type" => "object"},
        config
      )

  defp invoke(gateway, :session, config) do
    session = ChatSession.new(Broker.new("gpt-4o", gateway))
    original = ChatSession.messages(session)
    result = ChatSession.send(session, "payload-secret", recovery: config.recovery)
    assert ChatSession.messages(session) == original
    result
  end

  defp invoke(gateway, operation, config) do
    stream =
      case operation do
        :events ->
          gateway.complete_stream_events("gpt-4o", [Message.user("payload-secret")], config)

        :legacy ->
          gateway.complete_stream("gpt-4o", [Message.user("payload-secret")], [], config)

        :broker_stream ->
          Broker.generate_stream(
            Broker.new("gpt-4o", gateway),
            [Message.user("payload-secret")],
            [],
            config
          )

        :broker_events ->
          Broker.generate_stream_events(
            Broker.new("gpt-4o", gateway),
            [Message.user("payload-secret")],
            config
          )

        :session_stream ->
          session = ChatSession.new(Broker.new("gpt-4o", gateway))

          {:ok, stream, handle} =
            ChatSession.send_stream(session, "payload-secret", recovery: config.recovery)

          send(self(), {:permanent_session, session, ChatSession.messages(session), handle})
          stream
      end

    assert [{:error, error}] = Enum.to_list(stream)

    if operation == :session_stream do
      assert_receive {:permanent_session, session, original, handle}
      assert ChatSession.finalize_stream(handle) == {:error, error}
      assert ChatSession.messages(session) == original
    end

    {:error, error}
  end

  @tag :permanent_status_control
  test "explicit selection still admits transient 503 through ordinary OpenAI" do
    owner = self()
    success = Jason.encode!(%{choices: [%{message: %{content: "done", tool_calls: []}}]})

    server =
      start_supervised!(
        {ScriptedCompletionServer,
         {owner, [response(503, "transient-secret"), response(200, success)]}}
      )

    assert_receive {:server_port, port}
    configure(OpenAI, port)

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          retryable_categories: [:http, :transport],
          retryable_statuses: [400, 401, 403, 503],
          admission: fn context ->
            send(owner, {:control_admission, context})
            :allow
          end,
          sleeper: fn _ -> :ok end
        ]
      )

    assert {:ok, _} = invoke(OpenAI, :complete, config)
    assert_receive {:control_admission, context}
    assert context.failure.http_status == 503
    assert context.failure.retry_eligible
    assert [first, second] = GenServer.call(server, :requests)
    assert first == second
  end

  defp assert_exact_dispatched_request(
         trace,
         wire,
         started,
         expected_messages
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
