defmodule Mojentic.LLM.RetryAfterDatesWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedTransport

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)

    saved =
      Map.new(
        ["OPENAI_API_ENDPOINT", "OPENAI_API_KEY", "OLLAMA_HOST", "OMLX_HOST", "OMLX_API_KEY"],
        &{&1, System.get_env(&1)}
      )

    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)

      for {key, value} <- saved do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "RFC 850 structured recovery honors the date through real Req" do
    owner = self()
    body = "provider-sentinel"

    reply =
      "HTTP/1.1 429 Result\r\nRetry-After: Thursday, 01-Jan-26 00:00:03 GMT\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    server = start_supervised!({ScriptedTransport, {owner, [reply, reply]}})
    assert_receive {:transport_id, port}
    System.put_env("OPENAI_API_ENDPOINT", "http://127.0.0.1:#{port}/v1")
    System.put_env("OPENAI_API_KEY", "credential-sentinel")

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          admission: fn _ -> :allow end,
          base_delay: 10,
          jitter: fn _ -> 7 end,
          wall_clock: fn ->
            send(owner, :wall_observed)
            ~U[2026-01-01 00:00:00Z]
          end,
          sleeper: fn delay ->
            send(owner, {:scheduled, delay})
            :ok
          end
        ]
      )

    assert {:error, error} =
             OpenAI.complete_object(
               "fixture-model",
               [Message.user("input-sentinel")],
               %{"type" => "object"},
               config
             )

    assert error.retry_after == {:http_date, "2026-01-01T00:00:03Z"}
    assert_receive :wall_observed
    assert_receive {:scheduled, 3000}
    assert [first, second] = error.history
    assert first.retry_after == %{kind: :http_date, value: "2026-01-01T00:00:03Z"}
    assert first.logical_request_id == second.logical_request_id
    refute first.attempt_id == second.attempt_id
    assert_receive {:transport_request, wire}
    assert_receive {:transport_request, ^wire}
    assert wire =~ "POST /v1/chat/completions HTTP/1.1"
    [_, encoded] = String.split(wire, "\r\n\r\n", parts: 2)
    payload = Jason.decode!(encoded)
    assert payload["model"] == "fixture-model"
    assert payload["messages"] == [%{"role" => "user", "content" => "input-sentinel"}]
    assert GenServer.call(server, :requests) == [wire, wire]
    refute_received {:transport_request, _}
  end

  @tag :rfc850_rollover
  test "RFC 850 December 2076 rolls back to 1976 through real Req" do
    assert_date_boundary(
      OpenAI,
      :object,
      "Friday, 31-Dec-76 00:00:03 GMT",
      :future,
      {:http_date, "1976-12-31T00:00:03Z"},
      ~U[2026-10-16 00:00:03Z]
    )
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
      {label, header, expected, scenarios} <- [
        {:december_rollover, "Friday, 31-Dec-76 00:00:03 GMT",
         {:http_date, "1976-12-31T00:00:03Z"}, [:future]},
        {:before_cutoff, "Friday, 16-Oct-76 00:00:02 GMT", {:http_date, "2076-10-16T00:00:02Z"},
         [:ceiling, :cutoff_budget]},
        {:at_cutoff, "Friday, 16-Oct-76 00:00:03 GMT", {:http_date, "2076-10-16T00:00:03Z"},
         [:ceiling, :cutoff_budget]},
        {:after_cutoff, "Saturday, 16-Oct-76 00:00:04 GMT", {:http_date, "1976-10-16T00:00:04Z"},
         [:future]},
        {:wrong_selected_weekday, "Friday, 16-Oct-76 00:00:04 GMT", :invalid, [:future]}
      ],
      scenario <- scenarios do
    @gateway gateway
    @entrypoint entrypoint
    @header header
    @expected expected
    @scenario scenario
    @tag :rfc850_rollover
    @tag :retry_after_dates
    test "#{gateway} #{entrypoint} RFC 850 #{label} #{scenario} compares the complete 50-year cutoff through Req" do
      assert_date_boundary(
        @gateway,
        @entrypoint,
        @header,
        @scenario,
        @expected,
        ~U[2026-10-16 00:00:03Z]
      )
    end
  end

  # Local executable set retry-after-dates-v2. Scripted provider observations
  # exercise Req and the public consumers; paired provider verification is pending.
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
      {form, header} <- [
        {:imf, "Thu, 01 Jan 2026 00:00:03 GMT"},
        {:rfc850, "Thursday, 01-Jan-26 00:00:03 GMT"},
        {:asctime, "Thu Jan  1 00:00:03 2026"}
      ],
      scenario <- [:future, :past, :ceiling, :budget] do
    @gateway gateway
    @entrypoint entrypoint
    @header header
    @scenario scenario
    @tag :retry_after_dates
    test "#{gateway} #{entrypoint} #{form} #{scenario} normalizes metadata and enforces wire recovery limits" do
      assert_date_boundary(
        @gateway,
        @entrypoint,
        @header,
        @scenario,
        {:http_date, "2026-01-01T00:00:03Z"}
      )
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
      {label, header, expected} <- [
        {:seconds, "2", {:delay_seconds, 2}},
        {:absent, nil, :absent},
        {:invalid, "provider-sentinel", :invalid},
        {:invalid_calendar, "Thursday, 31-Feb-26 00:00:03 GMT", :invalid},
        {:invalid_weekday, "Fri Jan  1 00:00:03 2026", :invalid},
        {:invalid_time, "Thu Jan  1 25:00:03 2026", :invalid},
        {:past_century, "Sunday, 06-Nov-94 08:49:37 GMT", {:http_date, "1994-11-06T08:49:37Z"}}
      ] do
    @gateway gateway
    @entrypoint entrypoint
    @header header
    @expected expected
    @tag :retry_after_dates
    test "#{gateway} #{entrypoint} #{label} preserves existing Retry-After behavior through Req" do
      assert_date_boundary(@gateway, @entrypoint, @header, :future, @expected)
    end
  end

  defp assert_date_boundary(gateway, entrypoint, header, scenario, expected, reference \\ nil) do
    body = "provider-sentinel"
    date_header = if header, do: "Retry-After: #{header}\r\n", else: ""

    reply =
      "HTTP/1.1 429 Result\r\n#{date_header}Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    server = start_supervised!({ScriptedTransport, {self(), [reply, reply]}})
    assert_receive {:transport_id, port}
    configure(gateway, port)

    wall =
      reference ||
        if scenario == :past, do: ~U[2026-01-01 00:00:04Z], else: ~U[2026-01-01 00:00:00Z]

    config = CompletionConfig.new(recovery: date_policy(wall, scenario))
    error = invoke_with_history(gateway, entrypoint, config)
    attempts = if scenario in [:ceiling, :budget, :cutoff_budget], do: 1, else: 2
    assert error.retry_after == expected
    assert error.operation == operation(entrypoint)
    assert error.resend_permission == permission(scenario)
    requests = assert_history(error, expected, attempts, body)
    assert_events(error, expected, wall, attempts, header)
    wire_body = assert_wire(server, gateway, entrypoint, attempts)
    for request <- requests, do: assert(request.body == wire_body)
    [first | rest] = requests
    assert Enum.all?(rest, &(Map.delete(&1, :ids) == Map.delete(first, :ids)))
  end

  defp date_policy(wall, scenario) do
    owner = self()

    recovery = [
      max_attempts: 2,
      base_delay: 10,
      jitter: fn ceiling ->
        assert ceiling == 10
        7
      end,
      clock: fn -> 0 end,
      wall_clock: fn ->
        send(owner, {:wall_observed, wall})
        wall
      end,
      admission: fn context ->
        send(owner, {:date_admission, context})
        :allow
      end,
      observer: &send(owner, {:date_event, &1}),
      trace_observer: fn event ->
        if event.type == :request, do: send(owner, {:date_request, event})
        :ok
      end,
      sleeper: fn delay ->
        send(owner, {:date_delay, delay})
        :ok
      end
    ]

    Keyword.merge(recovery, limits(scenario))
  end

  defp invoke_with_history(gateway, entrypoint, config) do
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
    error
  end

  defp assert_history(error, expected, attempts, body) do
    assert error.http_status == 429
    assert error.category == :http
    assert error.wire_attempt == attempts
    assert length(error.history) == attempts
    assert Enum.map(error.history, & &1.wire_attempt) == Enum.to_list(1..attempts)
    assert length(Enum.uniq_by(error.history, & &1.attempt_id)) == attempts

    assert Enum.uniq(Enum.map(error.history, & &1.logical_request_id)) == [
             error.logical_request_id
           ]

    assert List.last(error.history).attempt_id == error.attempt_id

    for history <- error.history do
      assert history.retry_after == safe_retry_after(expected)
      assert history.http_status == 429
      assert history.progress.raw_bytes == byte_size(body)
      assert_receive {:date_request, request}
      assert request.ids == Map.take(history, [:logical_request_id, :attempt_id, :wire_attempt])
      request
    end
  end

  defp assert_events(error, expected, wall, attempts, header) do
    safe_retry = safe_retry_after(expected)
    assert_receive {:date_admission, context}
    assert context.failure.retry_after == safe_retry
    events = collect_events()
    failed = Enum.filter(events, &(&1.type == :attempt_failed))
    assert Enum.map(failed, & &1.metadata.attempt_id) == Enum.map(error.history, & &1.attempt_id)
    assert Enum.all?(failed, &(&1.metadata.retry_after == safe_retry))

    assert List.last(events) == %{
             type: :exhausted,
             metadata: Mojentic.TestSupport.StreamEvidence.recovery_snapshot(error)
           }

    assert_schedule(events, expected, wall, attempts)

    assert_safe_metadata(
      [inspect(error), Jason.encode!(error), inspect(events), inspect(context)],
      header,
      expected
    )
  end

  defp assert_schedule(events, expected, wall, attempts) do
    backoffs = Enum.filter(events, &(&1.type == :backoff_started))

    if attempts == 2 do
      delay = expected_delay(expected, wall)
      assert_receive {:date_delay, ^delay}
      assert [backoff] = backoffs
      assert backoff.metadata.delay_ms == delay
      assert backoff.metadata.retry_after == safe_retry_after(expected)
    else
      assert backoffs == []
    end

    refute_received {:date_delay, _}
    if match?({:http_date, _}, expected), do: assert_received({:wall_observed, ^wall})
  end

  defp assert_safe_metadata(values, header, expected) do
    for safe <- values do
      refute safe =~ "provider-sentinel"
      refute safe =~ "credential-sentinel"
      refute safe =~ "input-sentinel"
      if is_binary(header) and match?({:http_date, _}, expected), do: refute(safe =~ header)
    end
  end

  defp limits(:ceiling), do: [delay_ceiling: 2999]
  defp limits(:budget), do: [budget: 3000]
  defp limits(:cutoff_budget), do: [budget: 3000, delay_ceiling: 2_000_000_000_000]
  defp limits(_), do: []
  defp permission(:ceiling), do: :retry_after_ceiling
  defp permission(:budget), do: :deadline
  defp permission(:cutoff_budget), do: :deadline
  defp permission(_), do: :not_granted

  defp safe_retry_after({kind, value}), do: %{kind: kind, value: value}
  defp safe_retry_after(value), do: value

  defp expected_delay({:http_date, iso}, wall) do
    {:ok, date, 0} = DateTime.from_iso8601(iso)
    max(7, DateTime.diff(date, wall, :millisecond))
  end

  defp expected_delay({:delay_seconds, seconds}, _wall), do: max(7, seconds * 1000)
  defp expected_delay(_, _wall), do: 7

  defp collect_events(events \\ []) do
    receive do
      {:date_event, event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp configure(gateway, port) do
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end

    System.put_env("OPENAI_API_KEY", "credential-sentinel")
    System.put_env("OMLX_API_KEY", "credential-sentinel")
  end

  defp assert_wire(server, gateway, entrypoint, attempts) do
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

    if entrypoint in [:object, :broker_object] do
      if gateway == Ollama do
        assert payload["format"] == %{"type" => "object"}
      else
        assert payload["response_format"] == %{
                 "type" => "json_schema",
                 "json_schema" => %{"name" => "response", "schema" => %{"type" => "object"}}
               }
      end
    end

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
    encoded
  end

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
