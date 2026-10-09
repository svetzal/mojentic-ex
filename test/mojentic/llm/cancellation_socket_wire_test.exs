defmodule Mojentic.LLM.CancellationSocketWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{CompletionConfig, CompletionError, Message}
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
