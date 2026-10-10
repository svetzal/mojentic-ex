defmodule Mojentic.LLM.ProviderMetadataWireTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{Ollama, OMLX, OpenAI}
  alias Mojentic.TestSupport.ScriptedCompletionServer
  alias Mojentic.Tracer.TracerSystem

  @env_keys ~w(OPENAI_API_ENDPOINT OPENAI_API_KEY OLLAMA_HOST OMLX_HOST OMLX_API_KEY)
  @uuid "a539ba99-c7f8-4fd0-b324-d8b082925980"

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

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [
        :ordinary,
        :structured,
        :legacy,
        :events,
        :broker,
        :broker_object,
        :broker_legacy,
        :broker_events,
        :session,
        :session_legacy
      ],
      fixture <- [
        :token,
        :uuid,
        :recognized_code,
        :decorated_token,
        :decorated_uuid,
        :embedded_uuid,
        :embedded_short_token,
        :credential_uuid,
        :payload_uuid,
        :control_uuid,
        :control
      ],
      gateway != Ollama or fixture != :credential_uuid do
    @gateway gateway
    @operation operation
    @fixture fixture
    @tag :provider_metadata_echo
    test "#{gateway} #{operation} #{fixture} preserves safe metadata and immutable wire retries" do
      check_boundary(@gateway, @operation, @fixture)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:ordinary, :structured, :legacy, :events] do
    @gateway gateway
    @operation operation
    @tag :provider_metadata_cancellation
    test "#{gateway} #{operation} cancellation excludes received echoes and closes the socket" do
      check_cancellation(@gateway, @operation)
    end
  end

  defp check_cancellation(gateway, operation) do
    body = Jason.encode!(%{error: %{code: "overloaded"}})

    reply =
      response(body, @uuid)
      |> String.replace("Content-Length: #{byte_size(body)}", "Content-Length: 9999")

    server = start_supervised!({ScriptedCompletionServer, {self(), [{:stream_hold, reply}]}})
    assert_receive {:server_port, port}
    configure(gateway, port, "overloaded")
    tracer = start_supervised!({TracerSystem, []})
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()
    cancel = make_ref()

    config =
      CompletionConfig.new(
        recovery: [
          cancel_ref: cancel,
          observer: &send(owner, {:metadata_lifecycle, &1}),
          trace_observer: fn event ->
            send(owner, {:metadata_exact, event})
            :ok
          end
        ]
      )

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        invoke(gateway, operation, @uuid <> " overloaded", config, tracer)
      end)

    assert_receive {:wire_request, wire}, 2000
    assert_receive {:metadata_exact, %{type: :response_data, body: ^body}}, 2000
    send(task.pid, {:cancel, cancel})
    assert {:error, error} = Task.await(task, 2000)
    assert_cancelled_metadata(error, body)
    assert GenServer.call(server, {:peer_state, wire}) == {:error, :closed}
    assert GenServer.call(server, :requests) == [wire]
    events = for _ <- 1..3, do: receive_lifecycle()
    assert Enum.map(events, & &1.type) == [:attempt_started, :attempt_failed, :cancelled]
    assert List.last(events).metadata == CompletionError.safe_metadata(error)
    for event <- events, do: assert(event.metadata.attempt_id == error.attempt_id)
    assert_private(error, @uuid, tracer, events)
    refute inspect(events) =~ "overloaded"
  end

  defp assert_cancelled_metadata(error, body) do
    assert error.provider_request_id == nil
    assert error.provider_code == nil
    assert error.http_status == 503
    assert error.progress.headers_received
    assert error.progress.raw_bytes == byte_size(body)
    assert error.wire_attempt == 1
    assert CompletionError.received_evidence(error).body == body
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:legacy, :events] do
    @gateway gateway
    @operation operation
    @tag :provider_metadata_frame
    test "#{gateway} #{operation} semantic provider errors retain sensitive evidence privately" do
      provider_error = %{"code" => "overloaded", "message" => @uuid}
      decoded = Jason.encode!(%{"error" => provider_error})
      frame = if @gateway == Ollama, do: decoded <> "\n", else: "data: " <> decoded <> "\n\n"
      reply = response(frame, @uuid) |> String.replace("503 Result", "200 Result")
      server = start_supervised!({ScriptedCompletionServer, {self(), [reply]}})
      assert_receive {:server_port, port}
      configure(@gateway, port, "overloaded")
      owner = self()
      tracer = start_supervised!({TracerSystem, []})

      config =
        CompletionConfig.new(
          recovery: [
            trace_observer: fn event ->
              send(owner, {:metadata_exact, event})
              :ok
            end
          ]
        )

      assert {:error, error} =
               invoke(@gateway, @operation, @uuid <> " overloaded", config, tracer)

      assert error.provider_code == nil
      assert error.provider_request_id == nil
      assert error.http_status == 200
      assert error.progress.raw_bytes == byte_size(frame)
      assert CompletionError.cause(error) == {:provider_error, provider_error}
      evidence = CompletionError.received_evidence(error)
      assert evidence.status == 200
      assert {"x-request-id", @uuid} in evidence.headers
      assert Jason.decode!(evidence.body) == %{"error" => provider_error}
      assert_receive {:metadata_exact, %{type: :response_data, body: ^frame}}
      assert_receive {:wire_request, wire}
      assert GenServer.call(server, :requests) == [wire]
      assert_private(error, @uuid, tracer, CompletionError.safe_metadata(error))
    end
  end

  defp check_boundary(gateway, operation, fixture) do
    {secret, code, request_id, expected_code, expected_id} = fixture(fixture)
    body = Jason.encode!(%{error: %{code: code, message: secret}})

    prompt =
      case fixture do
        :credential_uuid -> "outbound-prompt-control"
        :embedded_uuid -> "Please use #{secret}."
        :embedded_short_token -> "Please use #{secret}."
        _ -> secret
      end

    credential =
      if fixture in [:payload_uuid, :embedded_uuid, :embedded_short_token],
        do: "credential-control",
        else: secret

    reply = response(body, request_id)
    server = start_supervised!({ScriptedCompletionServer, {self(), [reply, reply]}})
    assert_receive {:server_port, port}
    configure(gateway, port, credential)
    tracer = start_supervised!({TracerSystem, []})
    owner = self()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          base_delay: 0,
          sleeper: fn _ -> :ok end,
          admission: fn context ->
            send(owner, {:metadata_admission, context})
            :allow
          end,
          observer: &send(owner, {:metadata_lifecycle, &1}),
          trace_observer: fn event ->
            send(owner, {:metadata_exact, event})
            :ok
          end
        ]
      )

    log =
      capture_log(fn ->
        assert {:error, error} = invoke(gateway, operation, prompt, config, tracer)
        assert_failure(error, body, expected_code, expected_id)
        wire = assert_wire(server, gateway, prompt, credential)
        safe = assert_lifecycle(error)
        assert_inspection(error, body, request_id, wire)
        assert_private(error, secret, tracer, safe)
      end)

    refute log =~ secret
  end

  defp fixture(:token), do: echo("sk_fixtureCredential_123456789", false)
  defp fixture(:uuid), do: echo(@uuid, false)
  defp fixture(:embedded_uuid), do: echo(@uuid, true)
  defp fixture(:embedded_short_token), do: {"secret7", "secret7", "reqsecret7", nil, nil}
  defp fixture(:credential_uuid), do: echo(@uuid, false)
  defp fixture(:payload_uuid), do: echo(@uuid, false)

  defp fixture(:control_uuid),
    do: {"sk_fixtureCredential_123456789", "overloaded", @uuid, "overloaded", @uuid}

  defp fixture(:recognized_code), do: echo("overloaded", false)
  defp fixture(:decorated_token), do: echo("sk_fixtureCredential_123456789", true)
  defp fixture(:decorated_uuid), do: echo(@uuid, true)

  defp fixture(:control),
    do:
      {"sk_fixtureCredential_123456789", "overloaded", "req-legitimate-42", "overloaded",
       "req-legitimate-42"}

  defp echo(secret, decorated),
    do: {secret, secret, if(decorated, do: "req-" <> secret, else: secret), nil, nil}

  defp assert_failure(error, body, code, request_id) do
    assert %CompletionError{} = error
    assert error.provider_code == code
    assert error.provider_request_id == request_id
    assert error.http_status == 503
    assert error.wire_attempt == 2
    assert error.progress.headers_received
    assert error.progress.raw_bytes == byte_size(body)

    assert error.progress.observed == %{
             content: false,
             reasoning: false,
             tool_fragments: 0,
             completed_tool_calls: 0
           }

    assert error.progress.delivered == error.progress.observed
    assert [first, second] = error.history
    assert first.attempt_id != second.attempt_id
    assert second.attempt_id == error.attempt_id
    assert first.logical_request_id == error.logical_request_id
    assert second.logical_request_id == error.logical_request_id
    assert Enum.map(error.history, & &1.wire_attempt) == [1, 2]
    assert Regex.match?(~r/\A[0-9a-f-]{36}\z/, error.logical_request_id)
    assert Regex.match?(~r/\A[0-9a-f-]{36}\z/, error.attempt_id)
  end

  defp assert_wire(server, gateway, prompt, credential) do
    assert_receive {:wire_request, first}, 2000
    assert_receive {:wire_request, second}, 2000
    assert first == second
    assert GenServer.call(server, :requests) == [first, second]
    [headers, body] = String.split(first, "\r\n\r\n", parts: 2)
    assert Enum.any?(Jason.decode!(body)["messages"], &(&1["content"] == prompt))
    if gateway != Ollama, do: assert(headers =~ "Bearer #{credential}")
    refute_received {:wire_request, _}
    {headers, body}
  end

  defp assert_lifecycle(error) do
    events = for _ <- 1..9, do: receive_lifecycle()

    assert Enum.map(events, & &1.type) == [
             :attempt_started,
             :attempt_failed,
             :admission_pending,
             :admission_allowed,
             :backoff_started,
             :retry_started,
             :attempt_started,
             :attempt_failed,
             :exhausted
           ]

    [started, failed, _, _, _, _, retried, failure, terminal] = events
    assert started.metadata.attempt_id == failed.metadata.attempt_id
    assert retried.metadata.attempt_id == error.attempt_id
    assert terminal.metadata == CompletionError.safe_metadata(error)
    assert failure.metadata.attempt_id == error.attempt_id

    assert Enum.map(error.history, & &1.attempt_id) == [
             started.metadata.attempt_id,
             retried.metadata.attempt_id
           ]

    assert_receive {:metadata_admission, context}
    assert context.failure == failed.metadata
    assert context.previous_attempt_id == started.metadata.attempt_id
    assert context.logical_request_id == error.logical_request_id
    assert context.next_attempt == 2
    for event <- events, do: assert(event.metadata.logical_request_id == error.logical_request_id)
    {events, context}
  end

  defp receive_lifecycle do
    assert_receive {:metadata_lifecycle, event}
    event
  end

  defp assert_inspection(error, body, request_id, {wire_headers, wire_body}) do
    evidence = CompletionError.received_evidence(error)
    assert evidence.status == 503
    assert evidence.body == body
    assert {"x-request-id", request_id} in evidence.headers
    assert evidence.ids.attempt_id == error.attempt_id
    refute is_nil(CompletionError.cause(error))
    assert_receive {:metadata_exact, %{type: :request} = request}
    assert request.body == wire_body

    for {key, value} <- request.headers,
        do: assert(String.downcase(wire_headers) =~ String.downcase("#{key}: #{value}"))

    assert request.ids.logical_request_id == error.logical_request_id
    assert request.ids.attempt_id == hd(error.history).attempt_id
    assert_receive {:metadata_exact, %{type: :response_headers, status: 503} = headers}
    assert {"x-request-id", request_id} in headers.headers
    assert_receive {:metadata_exact, %{type: :response_data, body: ^body}}
  end

  defp assert_private(error, secret, tracer, safe) do
    tracing = TracerSystem.get_events(tracer)

    for serialized <- [
          inspect(error),
          Jason.encode!(error),
          Mojentic.Error.format_error(error),
          inspect(safe),
          inspect(tracing)
        ] do
      refute serialized =~ secret
    end
  end

  defp invoke(gateway, operation, secret, config, tracer) do
    messages = [Message.user(secret)]
    broker = Broker.new("gpt-4o", gateway, tracer: tracer)
    invoke_operation(operation, gateway, broker, messages, secret, config)
  end

  defp invoke_operation(:ordinary, gateway, _broker, messages, _secret, config),
    do: gateway.complete("gpt-4o", messages, [], config)

  defp invoke_operation(:structured, gateway, _broker, messages, _secret, config),
    do: gateway.complete_object("gpt-4o", messages, %{"type" => "object"}, config)

  defp invoke_operation(:legacy, gateway, _broker, messages, _secret, config),
    do: gateway.complete_stream("gpt-4o", messages, [], config) |> stream_error()

  defp invoke_operation(:events, gateway, _broker, messages, _secret, config),
    do: gateway.complete_stream_events("gpt-4o", messages, config) |> stream_error()

  defp invoke_operation(:broker, _gateway, broker, messages, _secret, config),
    do: Broker.generate(broker, messages, [], config)

  defp invoke_operation(:broker_object, _gateway, broker, messages, _secret, config),
    do: Broker.generate_object(broker, messages, %{"type" => "object"}, config)

  defp invoke_operation(:broker_legacy, _gateway, broker, messages, _secret, config),
    do: Broker.generate_stream(broker, messages, [], config) |> stream_error()

  defp invoke_operation(:broker_events, _gateway, broker, messages, _secret, config),
    do: Broker.generate_stream_events(broker, messages, config) |> stream_error()

  defp invoke_operation(:session, _gateway, broker, _messages, secret, config),
    do: ChatSession.send(ChatSession.new(broker), secret, recovery: config.recovery)

  defp invoke_operation(:session_legacy, _gateway, broker, _messages, secret, config) do
    session = ChatSession.new(broker)
    {:ok, stream, pending} = ChatSession.send_stream(session, secret, recovery: config.recovery)
    result = stream_error(stream)
    assert {:error, _} = ChatSession.finalize_stream(pending)
    result
  end

  defp stream_error(stream) do
    assert [{:error, error}] = Enum.to_list(stream)
    {:error, error}
  end

  defp configure(gateway, port, secret) do
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end

    System.put_env("OPENAI_API_KEY", secret)
    System.put_env("OMLX_API_KEY", secret)
  end

  defp response(body, request_id) do
    "HTTP/1.1 503 Result\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\nX-Request-ID: #{request_id}\r\n\r\n#{body}"
  end
end
