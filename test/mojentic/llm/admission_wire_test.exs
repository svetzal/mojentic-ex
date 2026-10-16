defmodule Mojentic.LLM.AdmissionWireTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)
    keys = ["OPENAI_API_ENDPOINT", "OLLAMA_HOST", "OMLX_HOST"]
    old = Map.new(keys, &{&1, System.get_env(&1)})
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)

      for {key, value} <- old do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      entrypoint <- [
        :complete,
        :object,
        :events,
        :legacy,
        :broker,
        :broker_object,
        :broker_events,
        :broker_legacy,
        :session,
        :session_stream
      ],
      outcome <- [
        :reject,
        nil,
        :unexpected,
        :raise,
        :throw,
        :exit,
        :kill,
        :cancelled,
        :deadline,
        :rejected,
        {:error, :allow}
      ] do
    @gateway gateway
    @entrypoint entrypoint
    @outcome outcome
    test "#{gateway} #{entrypoint} admission #{inspect(outcome)} preserves terminal identity and never resends" do
      assert_admission(@gateway, @entrypoint, @outcome)
    end
  end

  defp assert_admission(gateway, entrypoint, outcome) do
    reason = if outcome == :reject, do: :rejected, else: :admission_no_decision
    decision_event = if outcome == :reject, do: :admission_rejected, else: :admission_no_decision
    owner = self()
    body = "provider-sentinel"

    response =
      "HTTP/1.1 503 Unavailable\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    server = start_supervised!({ScriptedCompletionServer, {owner, [response]}})
    assert_receive {:server_port, port}
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          admission: fn context ->
            send(owner, {:admission, context})
            finish(outcome)
          end,
          observer: &send(owner, {:lifecycle, &1})
        ]
      )

    logs =
      capture_log(fn ->
        prior = [Message.user("earlier-input"), Message.assistant("earlier-output")]
        messages = prior ++ [Message.user("input-sentinel")]
        session = ChatSession.new(Broker.new("fixture-model", gateway))

        session = %{
          session
          | messages: session.messages ++ Enum.map(prior, &%{message: &1, token_length: 1})
        }

        original_history = session.messages

        assert {:error, %CompletionError{} = error} =
                 invoke(gateway, entrypoint, config, messages, session)

        assert session.messages == original_history
        assert messages == prior ++ [Message.user("input-sentinel")]

        assert_failure(error, gateway, entrypoint, reason, body)
        assert_lifecycle(error, reason, decision_event)
        assert_wire(server, gateway, entrypoint)
      end)

    refute logs =~ "callback-sentinel"
  end

  defp assert_failure(error, gateway, entrypoint, reason, body) do
    assert error.resend_permission == reason
    assert error.http_status == 503
    assert error.category == :http
    assert error.reason == :http_status
    assert error.acceptance == :unknown
    assert error.retry_eligible
    assert error.provider_code == nil
    assert error.provider_request_id == nil
    assert error.retry_after == :absent
    assert error.provider == provider(gateway)
    assert_progress(error.progress, body)
    assert error.wire_attempt == 1
    assert error.operation == operation(entrypoint)
  end

  defp assert_lifecycle(error, reason, decision_event) do
    assert_receive {:admission, context}

    events =
      for _ <- 1..5 do
        assert_receive {:lifecycle, event}
        event
      end

    assert [
             %{type: :attempt_started, metadata: started},
             %{type: :attempt_failed, metadata: failed},
             %{type: :admission_pending, metadata: pending},
             %{type: ^decision_event, metadata: undecided},
             %{type: :exhausted, metadata: terminal}
           ] = events

    assert terminal == CompletionError.safe_metadata(error)
    assert pending == failed
    assert undecided == failed
    assert context.failure == failed
    assert context.logical_request_id == error.logical_request_id
    assert context.previous_attempt_id == error.attempt_id
    assert context.next_attempt == 2

    assert Map.take(started, [:logical_request_id, :attempt_id, :wire_attempt]) ==
             Map.take(terminal, [:logical_request_id, :attempt_id, :wire_attempt])

    assert error.history == [Map.delete(failed, :history)]
    assert terminal == %{failed | resend_permission: reason}

    for value <- [
          inspect(error),
          Jason.encode!(error),
          inspect(terminal),
          inspect(context),
          inspect([started, failed, pending, undecided])
        ] do
      refute value =~ "callback-sentinel"
      refute value =~ "provider-sentinel"
      refute value =~ "input-sentinel"
    end
  end

  defp assert_wire(server, gateway, entrypoint) do
    assert_receive {:wire_request, wire}
    path = if gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions"
    assert wire =~ path
    [_, encoded] = String.split(wire, "\r\n\r\n", parts: 2)
    payload = Jason.decode!(encoded)

    expected_messages = [
      %{"role" => "user", "content" => "earlier-input"},
      %{"role" => "assistant", "content" => "earlier-output"},
      %{"role" => "user", "content" => "input-sentinel"}
    ]

    expected_messages =
      if entrypoint in [:session, :session_stream],
        do: [
          %{"role" => "system", "content" => "You are a helpful assistant."} | expected_messages
        ],
        else: expected_messages

    assert payload["messages"] == expected_messages

    assert payload["model"] == "fixture-model"

    expected_stream =
      cond do
        operation(entrypoint) in [:complete_stream, :complete_stream_events] -> true
        gateway == Ollama -> false
        true -> nil
      end

    assert payload["stream"] == expected_stream
    assert GenServer.call(server, :requests) == [wire]
    refute_receive {:wire_request, _}
    refute_received {:lifecycle, _}
  end

  defp provider(OpenAI), do: :openai
  defp provider(Ollama), do: :ollama
  defp provider(OMLX), do: :omlx

  defp assert_progress(progress, body) do
    empty = %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

    assert progress == %{
             headers_received: true,
             raw_bytes: byte_size(body),
             observed: empty,
             delivered: empty
           }
  end

  defp finish(:raise), do: raise("callback-sentinel")
  defp finish(:throw), do: throw("callback-sentinel")
  defp finish(:exit), do: exit("callback-sentinel")
  defp finish(:kill), do: Process.exit(self(), :kill)
  defp finish(value), do: value

  defp operation(entrypoint) when entrypoint in [:object, :broker_object], do: :complete_object

  defp operation(entrypoint) when entrypoint in [:events, :broker_events],
    do: :complete_stream_events

  defp operation(entrypoint) when entrypoint in [:legacy, :broker_legacy, :session_stream],
    do: :complete_stream

  defp operation(_), do: :complete

  defp invoke(gateway, :complete, config, messages, _session),
    do: gateway.complete("fixture-model", messages, [], config)

  defp invoke(gateway, :object, config, messages, _session),
    do: gateway.complete_object("fixture-model", messages, %{"type" => "object"}, config)

  defp invoke(gateway, :events, config, messages, _session),
    do: gateway.complete_stream_events("fixture-model", messages, config) |> stream_error()

  defp invoke(gateway, :legacy, config, messages, _session),
    do: gateway.complete_stream("fixture-model", messages, nil, config) |> stream_error()

  defp invoke(gateway, :broker, config, messages, _session),
    do: Broker.generate(Broker.new("fixture-model", gateway), messages, nil, config)

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
      Broker.generate_stream(Broker.new("fixture-model", gateway), messages, nil, config)
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
    assert [{:error, %CompletionError{}} = result] = Enum.to_list(stream)
    result
  end
end
