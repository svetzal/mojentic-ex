defmodule Mojentic.LLM.TypedErrorsWireTest do
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

  @tag :typed_error_proof
  test "session retains typed length failure through the real Req boundary" do
    body =
      Jason.encode!(%{
        choices: [%{message: %{content: "partial-secret"}, finish_reason: "length"}]
      })

    server = start_supervised!({ScriptedCompletionServer, {self(), [response(200, body)]}})
    assert_receive {:server_port, port}
    configure(OpenAI, port)
    session = ChatSession.new(Broker.new("gpt-4o", OpenAI))

    assert {:error, %CompletionError{category: :protocol, retry_eligible: false} = error} =
             ChatSession.send(session, "payload-secret", recovery: [max_attempts: 2])

    assert CompletionError.cause(error) == {:incomplete_completion, "length"}
    assert CompletionError.received_evidence(error).body == body
    assert [request] = GenServer.call(server, :requests)
    assert request =~ "payload-secret"
    refute inspect(error) =~ "partial-secret"
    assert length(error.history) == 1
  end

  @tag :policy_proof
  test "invalid session stream policy is a typed policy failure" do
    server = start_supervised!({ScriptedCompletionServer, {self(), []}})
    assert_receive {:server_port, port}
    configure(OpenAI, port)
    session = ChatSession.new(Broker.new("gpt-4o", OpenAI))

    assert {:ok, stream, handle} =
             ChatSession.send_stream(session, "payload-secret", recovery: false)

    assert [{:error, %CompletionError{category: :policy, reason: :unsupported_options} = error}] =
             Enum.to_list(stream)

    assert ChatSession.finalize_stream(handle) == {:error, error}
    assert GenServer.call(server, :requests) == []
  end

  @entrypoints [
    :complete,
    :object,
    :events,
    :legacy,
    :broker,
    :broker_response,
    :broker_object,
    :broker_events,
    :broker_legacy,
    :session,
    :session_stream
  ]

  for gateway <- [OpenAI, Ollama, OMLX],
      entrypoint <- @entrypoints,
      scenario <- [:policy, :capture, :length] do
    @gateway gateway
    @entrypoint entrypoint
    @scenario scenario
    test "#{gateway} #{entrypoint} #{@scenario} retains typed cause and forbids replay" do
      assert_boundary(@gateway, @entrypoint, @scenario)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], entrypoint <- [:object, :broker_object] do
    @gateway gateway
    @entrypoint entrypoint
    test "#{gateway} #{entrypoint} truncated JSON retains length rather than a parser error" do
      body =
        completion_body(@gateway, @entrypoint, :length)
        |> String.replace("{}", "{")

      server = start_supervised!({ScriptedCompletionServer, {self(), [response(200, body)]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)
      {messages, session} = conversation(@gateway)
      config = CompletionConfig.new(recovery: [max_attempts: 3])

      assert {:error, %CompletionError{reason: :incomplete_completion} = error} =
               invoke(@gateway, @entrypoint, config, messages, session)

      assert CompletionError.cause(error) == {:incomplete_completion, "length"}
      assert CompletionError.received_evidence(error).body == body
      assert [_] = GenServer.call(server, :requests)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    test "#{gateway} legacy ordinary length response remains successful without recovery" do
      body = completion_body(@gateway, :complete, :length)
      server = start_supervised!({ScriptedCompletionServer, {self(), [response(200, body)]}})
      assert_receive {:server_port, port}
      configure(@gateway, port)

      assert {:ok, %Mojentic.LLM.GatewayResponse{finish_reason: "length", content: "{}"}} =
               @gateway.complete(
                 "fixture-model",
                 [Message.user("input-sentinel")],
                 nil,
                 CompletionConfig.new()
               )

      assert [_] = GenServer.call(server, :requests)
    end
  end

  defp assert_boundary(gateway, entrypoint, :policy) do
    server = start_supervised!({ScriptedCompletionServer, {self(), []}})
    assert_receive {:server_port, port}
    configure(gateway, port)
    {messages, session} = conversation(gateway)

    for policy <- [
          false,
          :invalid,
          ["bad"],
          [unknown: "policy-secret"],
          [max_attempts: 0],
          [admission: fn -> :allow end],
          [retryable_statuses: [200]],
          [retryable_categories: [:protocol]]
        ] do
      assert {:error, %CompletionError{category: :policy, reason: :unsupported_options} = error} =
               invoke(
                 gateway,
                 entrypoint,
                 CompletionConfig.new(recovery: policy),
                 messages,
                 session
               )

      assert CompletionError.cause(error) == :unsupported_options
      assert error.acceptance == :no
      assert error.wire_attempt == 0
      assert error.history == []
      refute error.retry_eligible
      assert GenServer.call(server, :requests) == []
      refute inspect(error) =~ "policy-secret"
      refute_received {:tool_executed, _}
      refute_receive {:wire_request, _}, 10
    end
  end

  defp assert_boundary(gateway, entrypoint, scenario) do
    owner = self()
    body = completion_body(gateway, entrypoint, scenario)
    server = start_supervised!({ScriptedCompletionServer, {owner, [response(200, body)]}})
    assert_receive {:server_port, port}
    configure(gateway, port)
    {messages, session} = conversation(gateway)
    history = session.messages

    recovery = [
      max_attempts: 3,
      retryable_categories: [:transport, :http, :client_timeout],
      admission: fn _ ->
        send(owner, :unexpected_admission)
        :allow
      end,
      observer: &send(owner, {:typed_lifecycle, &1}),
      trace_observer: fn event ->
        send(owner, {:typed_trace, event})
        if scenario == :capture and event.type == :response_end, do: raise("capture-secret")
        :ok
      end
    ]

    assert {:error, %CompletionError{category: :protocol, retry_eligible: false} = error} =
             invoke(
               gateway,
               entrypoint,
               CompletionConfig.new(recovery: recovery),
               messages,
               session
             )

    assert_cause(error, scenario)
    assert error.wire_attempt == 1
    assert [attempt] = error.history
    assert attempt.attempt_id == error.attempt_id
    assert attempt.logical_request_id == error.logical_request_id
    assert attempt.category == :protocol
    assert attempt.retry_eligible == false
    assert error.resend_permission != :granted
    assert session.messages == history
    assert_wire(server, entrypoint, messages, history)

    if entrypoint in [:complete, :object, :broker, :broker_response, :broker_object, :session] do
      assert CompletionError.received_evidence(error).body == body
    end

    assert trace_body() == body
    assert_lifecycle(error, scenario)
    refute_received :unexpected_admission
    refute_received {:tool_executed, _}
    refute_receive {:wire_request, _}, 10
  end

  defp assert_wire(server, entrypoint, messages, history) do
    assert_receive {:wire_request, wire}
    assert GenServer.call(server, :requests) == [wire]
    assert_receive {:typed_trace, %{type: :request, body: encoded}}
    [_, recorded] = String.split(wire, "\r\n\r\n", parts: 2)
    assert encoded == recorded
    payload = Jason.decode!(recorded)

    expected =
      if entrypoint in [:session, :session_stream],
        do: Enum.map(history, & &1.message) ++ [Message.user("input-sentinel")],
        else: messages

    assert payload["messages"] ==
             Enum.map(expected, &%{"role" => to_string(&1.role), "content" => &1.content})

    assert payload["model"] == "fixture-model"
  end

  defp assert_lifecycle(error, scenario) do
    events = lifecycle_events()
    assert Enum.map(events, & &1.type) == [:attempt_started, :attempt_failed, :exhausted]
    assert List.last(events).metadata == CompletionError.safe_metadata(error)
    assert Enum.at(events, 1).metadata.attempt_id == error.attempt_id

    for value <- [inspect(error), Jason.encode!(error), inspect(events)] do
      for secret <- ["capture-secret", "input-sentinel", "tool-secret"],
          do: refute(value =~ secret)
    end

    terminal = List.last(events).metadata
    assert terminal.category == :protocol
    assert terminal.retry_eligible == false
    assert terminal.phase in [:unknown, :decoding, :streaming]

    expected_acceptance =
      if scenario == :length and error.operation in [:complete, :complete_object],
        do: :yes,
        else: :unknown

    assert terminal.acceptance == expected_acceptance
    assert terminal.reason == error.reason
    assert terminal.operation == error.operation
    refute Map.has_key?(terminal, :delay)
  end

  defp assert_cause(error, :capture) do
    assert error.reason == :capture_failed
    assert CompletionError.cause(error) == :capture_failed
  end

  defp assert_cause(error, :length) do
    assert {:incomplete_completion, retained} = CompletionError.cause(error)
    assert retained == "length" or (is_map(retained) and retained.finish_reason == "length")
  end

  defp trace_body(acc \\ "") do
    receive do
      {:typed_trace, %{type: :response_data, body: body}} -> trace_body(acc <> body)
    after
      0 -> acc
    end
  end

  defp lifecycle_events(acc \\ []) do
    receive do
      {:typed_lifecycle, event} -> lifecycle_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp conversation(gateway) do
    prior = [Message.user("earlier-input"), Message.assistant("earlier-output")]

    session =
      ChatSession.new(Broker.new("fixture-model", gateway),
        tools: [%Mojentic.TestSupport.CountingTool{owner: self()}]
      )

    session = %{
      session
      | messages: session.messages ++ Enum.map(prior, &%{message: &1, token_length: 1})
    }

    {prior ++ [Message.user("input-sentinel")], session}
  end

  defp completion_body(gateway, entrypoint, scenario) do
    reason = if scenario == :length, do: "length", else: "stop"

    if entrypoint in [:events, :legacy, :broker_events, :broker_legacy, :session_stream] do
      stream_body(gateway, reason, entrypoint)
    else
      call =
        if gateway == Ollama,
          do: %{function: %{name: "count", arguments: %{value: "tool-secret"}}},
          else: %{
            id: "call-17",
            type: "function",
            function: %{name: "count", arguments: ~s({"value":"tool-secret"})}
          }

      message = %{content: "{}", tool_calls: [call]}

      if gateway == Ollama,
        do: Jason.encode!(%{message: message, done: true, done_reason: reason}),
        else: Jason.encode!(%{choices: [%{message: message, finish_reason: reason}]})
    end
  end

  defp stream_body(gateway, reason, entrypoint) do
    message = %{content: "{}"}

    message =
      if reason == "length" and entrypoint in [:legacy, :broker_legacy, :session_stream] do
        call =
          if gateway == Ollama,
            do: %{function: %{name: "count", arguments: %{value: "tool-secret"}}},
            else: %{
              index: 0,
              id: "call-17",
              type: "function",
              function: %{name: "count", arguments: ~s({"value":"tool-secret"})}
            }

        Map.put(message, :tool_calls, [call])
      else
        message
      end

    if gateway == Ollama do
      Jason.encode!(%{message: message, done: true, done_reason: reason}) <> "\n"
    else
      "data: " <>
        Jason.encode!(%{choices: [%{delta: message, finish_reason: reason}]}) <>
        "\n\ndata: [DONE]\n\n"
    end
  end

  defp invoke(gateway, :complete, config, messages, _session),
    do: gateway.complete("fixture-model", messages, [], config)

  defp invoke(gateway, :object, config, messages, _session),
    do: gateway.complete_object("fixture-model", messages, %{"type" => "object"}, config)

  defp invoke(gateway, :events, config, messages, _session),
    do: gateway.complete_stream_events("fixture-model", messages, config) |> stream_error()

  defp invoke(gateway, :legacy, config, messages, _session),
    do:
      gateway.complete_stream(
        "fixture-model",
        messages,
        [%Mojentic.TestSupport.CountingTool{owner: self()}],
        config
      )
      |> stream_error()

  defp invoke(gateway, :broker, config, messages, _session),
    do:
      Broker.generate(
        Broker.new("fixture-model", gateway),
        messages,
        [%Mojentic.TestSupport.CountingTool{owner: self()}],
        config
      )

  defp invoke(gateway, :broker_response, config, messages, _session),
    do:
      Broker.generate_response(
        Broker.new("fixture-model", gateway),
        messages,
        [%Mojentic.TestSupport.CountingTool{owner: self()}],
        config
      )

  defp invoke(gateway, :broker_object, config, messages, _session),
    do:
      Broker.generate_object(
        Broker.new("fixture-model", gateway),
        messages,
        %{"type" => "object"},
        config
      )

  defp invoke(gateway, :broker_events, config, messages, _session),
    do:
      Broker.generate_stream_events(Broker.new("fixture-model", gateway), messages, config)
      |> stream_error()

  defp invoke(gateway, :broker_legacy, config, messages, _session),
    do:
      Broker.generate_stream(
        Broker.new("fixture-model", gateway),
        messages,
        [%Mojentic.TestSupport.CountingTool{owner: self()}],
        config
      )
      |> stream_error()

  defp invoke(_gateway, :session, config, _messages, session),
    do: ChatSession.send(session, "input-sentinel", recovery: config.recovery)

  defp invoke(_gateway, :session_stream, config, _messages, session) do
    assert {:ok, stream, pending_session} =
             ChatSession.send_stream(session, "input-sentinel", recovery: config.recovery)

    result = stream_error(stream)
    assert ChatSession.finalize_stream(pending_session) == result
    result
  end

  defp stream_error(stream) do
    events = Enum.to_list(stream)
    assert {:error, %CompletionError{}} = result = List.last(events)
    assert Enum.count(events, &match?({:error, _}, &1)) == 1
    refute Enum.any?(events, &match?({:completed, _}, &1))
    result
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
