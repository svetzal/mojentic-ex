defmodule Mojentic.LLM.AdmissionWireTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedTransport

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
      scenario <- [:eligible, :ineligible, :single_attempt, :nonacceptance] do
    @gateway gateway
    @entrypoint entrypoint
    @scenario scenario
    @tag :no_hook
    test "#{gateway} #{entrypoint} no hook #{@scenario} preserves wire and lifecycle contract" do
      assert_no_hook(@gateway, @entrypoint, @scenario)
    end
  end

  defp assert_no_hook(gateway, entrypoint, scenario) do
    owner = self()
    status = if scenario == :ineligible, do: 400, else: 503
    body = "provider-sentinel"

    response =
      "HTTP/1.1 #{status} Result\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    prior = [Message.user("earlier-input"), Message.assistant("earlier-output")]
    messages = prior ++ [Message.user("input-sentinel")]
    session = ChatSession.new(Broker.new("fixture-model", gateway))

    session = %{
      session
      | messages: session.messages ++ Enum.map(prior, &%{message: &1, token_length: 1})
    }

    original_history = session.messages
    attempts = if scenario == :single_attempt, do: 1, else: 2

    recovery = [
      max_attempts: attempts,
      base_delay: 0,
      trace_observer: fn event ->
        if event.type == :request, do: send(owner, {:no_hook_request, event})
        :ok
      end,
      observer: &send(owner, {:lifecycle, &1}),
      sleeper: fn _ -> :ok end
    ]

    recovery =
      if scenario == :single_attempt, do: Keyword.delete(recovery, :max_attempts), else: recovery

    {server, error} =
      if scenario == :nonacceptance do
        refused_then_observed(gateway, entrypoint, recovery, messages, session, response)
      else
        server = start_supervised!({ScriptedTransport, {owner, [response, response]}})
        assert_receive {:transport_id, port}
        configure_no_hook(gateway, port)
        config = CompletionConfig.new(recovery: recovery)

        assert {:error, %CompletionError{} = error} =
                 invoke(gateway, entrypoint, config, messages, session)

        {server, error}
      end

    retried = scenario == :nonacceptance or (scenario == :eligible and gateway == OpenAI)
    wire_count = if retried, do: 2, else: 1
    assert_wire(server, gateway, entrypoint, wire_count)
    assert session.messages == original_history
    assert error.http_status == status
    assert error.category == :http
    assert error.acceptance == :unknown
    assert error.retry_eligible == (status == 503)
    assert error.provider == provider(gateway)
    assert error.operation == operation(entrypoint)
    assert_no_hook_history(error, retried)
    assert_no_hook_requests(server, error)

    required = gateway != OpenAI and scenario == :eligible
    assert error.resend_permission == if(required, do: :admission_required, else: :not_granted)
    assert_no_hook_events(error, retried, required, scenario)
  end

  defp assert_no_hook_history(error, retried) do
    expected_attempts = if retried, do: 2, else: 1
    assert error.wire_attempt == expected_attempts
    assert length(error.history) == expected_attempts
    assert Enum.map(error.history, & &1.wire_attempt) == Enum.to_list(1..expected_attempts)
    assert length(Enum.uniq_by(error.history, & &1.attempt_id)) == expected_attempts

    assert Enum.uniq(Enum.map(error.history, & &1.logical_request_id)) == [
             error.logical_request_id
           ]

    assert List.last(error.history).attempt_id == error.attempt_id
  end

  defp assert_no_hook_requests(server, error) do
    requests =
      for history <- error.history do
        assert_receive {:no_hook_request, request}
        assert request.ids == Map.take(history, [:logical_request_id, :attempt_id, :wire_attempt])
        request
      end

    [first | rest] = requests
    assert Enum.all?(rest, &(Map.delete(&1, :ids) == Map.delete(first, :ids)))
    [wire | _] = GenServer.call(server, :requests)
    [_, body] = String.split(wire, "\r\n\r\n", parts: 2)
    assert first.body == body
    refute_received {:no_hook_request, _}
  end

  defp refused_then_observed(gateway, entrypoint, recovery, messages, session, response) do
    server = start_supervised!({ScriptedTransport, {self(), [{:error, :econnrefused}, response]}})
    assert_receive {:transport_id, port}
    configure_no_hook(gateway, port)
    owner = self()

    recovery =
      Keyword.put(recovery, :sleeper, fn _ ->
        send(owner, {:install_provider, self()})

        receive do
          :provider_ready -> :ok
        after
          2000 -> :not_ready
        end
      end)

    config = CompletionConfig.new(recovery: recovery)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        invoke(gateway, entrypoint, config, messages, session)
      end)

    assert_receive {:install_provider, worker}, 2000
    send(worker, :provider_ready)
    assert {:error, %CompletionError{} = error} = Task.await(task, 2000)
    assert [refused, _] = error.history
    assert refused.category == :transport
    assert refused.reason == :connection_refused
    assert refused.phase == :connecting
    assert refused.acceptance == :no
    assert refused.retry_eligible
    assert refused.http_status == nil
    assert refused.progress.raw_bytes == 0
    {server, error}
  end

  defp configure_no_hook(gateway, port) do
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end
  end

  defp assert_no_hook_events(error, retried, required, scenario) do
    types =
      cond do
        retried ->
          [
            :attempt_started,
            :attempt_failed,
            :admission_allowed,
            :backoff_started,
            :retry_started,
            :attempt_started,
            :attempt_failed,
            :exhausted
          ]

        required ->
          [:attempt_started, :attempt_failed, :admission_required, :exhausted]

        true ->
          [:attempt_started, :attempt_failed, :exhausted]
      end

    events =
      for _ <- types do
        assert_receive {:lifecycle, event}
        event
      end

    assert Enum.map(events, & &1.type) == types

    assert List.last(events).metadata ==
             Mojentic.TestSupport.StreamEvidence.recovery_snapshot(error)

    failures = Enum.filter(events, &(&1.type == :attempt_failed))
    assert Enum.map(failures, &Map.delete(&1.metadata, :history)) == error.history

    if scenario == :nonacceptance do
      assert Enum.at(events, 2).metadata.acceptance == :no
    end

    refute_received {:lifecycle, _}
  end

  defp assert_admission(gateway, entrypoint, outcome) do
    reason = if outcome == :reject, do: :rejected, else: :admission_no_decision
    decision_event = if outcome == :reject, do: :admission_rejected, else: :admission_no_decision
    owner = self()
    body = "provider-sentinel"

    response =
      "HTTP/1.1 503 Unavailable\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    server = start_supervised!({ScriptedTransport, {owner, [response]}})
    assert_receive {:transport_id, port}
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
        refute_received {:lifecycle, _}
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

    assert terminal == Mojentic.TestSupport.StreamEvidence.recovery_snapshot(error)
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

  defp assert_wire(server, gateway, entrypoint, attempts \\ 1) do
    assert_receive {:transport_request, wire}
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

    if attempts == 2 do
      assert_receive {:transport_request, ^wire}
    end

    assert GenServer.call(server, :requests) == List.duplicate(wire, attempts)
    refute_received {:transport_request, _}
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
