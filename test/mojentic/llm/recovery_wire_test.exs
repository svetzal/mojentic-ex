defmodule Mojentic.LLM.RecoveryWireTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer
  alias Mojentic.Tracer.TracerSystem

  @env_keys ["OPENAI_API_ENDPOINT", "OPENAI_API_KEY", "OLLAMA_HOST", "OMLX_HOST", "OMLX_API_KEY"]
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
    test "#{gateway} #{operation} Req sees one exact request and never retries a 503" do
      body = ~s({ "error": { "code": "overloaded", "message": "response-secret" } })

      server =
        start_supervised!(
          {ScriptedCompletionServer, {self(), [response(503, body), response(200, "{}")]}}
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
          assert error.http_status == 503
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
