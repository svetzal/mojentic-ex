defmodule Mojentic.LLM.RecoveryWireTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer
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
