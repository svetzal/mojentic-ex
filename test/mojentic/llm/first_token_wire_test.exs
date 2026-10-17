defmodule Mojentic.LLM.FirstTokenWireTest do
  use ExUnit.Case, async: false

  import Mox

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.TestSupport.FirstTokenContract, as: Contract
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer

  @moduletag capture_log: true
  @milestones Contract.contract()["milestones"]

  setup do
    # The clock is a boundary; its implementation reads controlled milestones.
    clock =
      start_supervised!(%{
        id: :clock,
        start: {Agent, :start_link, [fn -> @milestones["construction"] end]}
      })

    old_client = Application.fetch_env!(:mojentic, :http_client)
    old_clock = Application.get_env(:mojentic, :monotonic_clock)
    keys = ["OPENAI_API_ENDPOINT", "OPENAI_API_KEY", "OLLAMA_HOST", "OMLX_HOST", "OMLX_API_KEY"]
    old_hosts = Map.new(keys, &{&1, System.get_env(&1)})
    set_mox_global()
    stub(Mojentic.MonotonicClockMock, :now, fn -> Agent.get(clock, & &1) end)
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
    Application.put_env(:mojentic, :monotonic_clock, Mojentic.MonotonicClockMock)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, old_client)

      if old_clock,
        do: Application.put_env(:mojentic, :monotonic_clock, old_clock),
        else: Application.delete_env(:mojentic, :monotonic_clock)

      Enum.each(old_hosts, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    %{clock: clock}
  end

  @tag :first_token_proof
  test "split-frame observation survives rejected capture without output or resend", %{
    clock: clock
  } do
    owner = self()

    token =
      "data: {\"choices\":[{\"delta\":{\"content\":\"answer\",\"reasoning_content\":\"thought\"}}]}\n\n"

    split = byte_size(token) - 4
    <<prefix::binary-size(split), suffix::binary>> = token

    headers =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"

    server =
      start_supervised!(
        {ScriptedCompletionServer, {owner, [{:stream_hold, headers <> chunk(prefix)}], 0, 1}}
      )

    assert_receive {:server_port, port}
    System.put_env("OMLX_HOST", "http://127.0.0.1:#{port}")

    trace = fn
      %{type: :request} ->
        Agent.update(clock, fn _ -> @milestones["prefix"] end)

      %{type: :response_data, body: ^prefix} ->
        send(owner, :prefix_captured)
        :ok

      %{type: :response_data} ->
        send(owner, {:capture_waiting, self()})

        receive do
          :reject -> {:error, :rejected}
        end

      _ ->
        :ok
    end

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          trace_observer: trace,
          admission: fn _ ->
            send(owner, :admitted)
            :allow
          end
        ]
      )

    stream = OMLX.complete_stream_events("local", [Message.user("hello")], config)
    Agent.update(clock, fn _ -> @milestones["dispatch"] end)
    task = collect_async(stream)
    assert_receive :prefix_captured, 3000
    Agent.update(clock, fn _ -> @milestones["frame"] end)
    :ok = GenServer.call(server, {:release, chunk(suffix) <> "0\r\n\r\n"})
    assert_receive {:capture_waiting, worker}, 3000
    task_ref = task.ref
    refute_receive {^task_ref, _}, 0
    Agent.update(clock, fn _ -> @milestones["terminal"] end)
    send(worker, :reject)
    assert [{:error, %CompletionError{} = error}] = Task.await(task)
    assert error.reason == :capture_failed

    assert Map.get(error, :metadata) == %{
             time_to_first_token_ms: 25,
             first_token_kind: :thinking,
             request_duration_ms: 80
           }

    refute error.progress.delivered.content
    refute error.progress.delivered.reasoning
    assert error.progress.observed.content
    assert error.progress.observed.reasoning
    assert [request] = GenServer.call(server, :requests)
    assert String.starts_with?(request, "POST /v1/chat/completions HTTP/1.1\r\n")

    assert request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!() == %{
             "model" => "local",
             "messages" => [%{"role" => "user", "content" => "hello"}],
             "stream" => true,
             "stream_options" => %{"include_usage" => true}
           }

    refute_receive :admitted
  end

  for provider <- [:openai, :ollama, :omlx],
      route <- [:events, :legacy, :broker_events, :broker_legacy, :session],
      row <- Contract.contract()["cases"],
      outcome <- [:delayed, :rejected, :cancelled] do
    @provider provider
    @route route
    @row row
    @outcome outcome
    @tag :first_token_contract
    test "#{provider} #{route} #{@row["name"]} split capture #{outcome} retains observation and terminal timing",
         %{clock: clock} do
      capture_probe(@provider, @route, @row, @outcome, clock)
    end
  end

  for provider <- [:openai, :ollama, :omlx],
      route <- [:events, :legacy, :broker_events, :broker_legacy, :session],
      row <- Contract.contract()["cases"] do
    @provider provider
    @route route
    @row row
    @tag :first_token_contract
    test "#{provider} #{route} #{@row["name"]} without recovery measures the production dispatch",
         %{clock: clock} do
      untraced_probe(@provider, @route, @row, clock)
    end
  end

  for provider <- [:openai, :ollama, :omlx],
      route <- [:events, :legacy, :broker_events, :broker_legacy, :session] do
    @provider provider
    @route route
    @tag :first_token_contract
    test "#{provider} #{route} admitted retry spans one dispatch clock and repeats exact wire request",
         %{clock: clock} do
      provider = @provider
      owner = self()
      busy = "{\"error\":\"busy\"}"

      first =
        "HTTP/1.1 503 Busy\r\nContent-Length: #{byte_size(busy)}\r\nConnection: close\r\n\r\n#{busy}"

      wire = Contract.frame(provider, %{"content" => "answer"}) <> Contract.terminal(provider)
      second = Contract.headers() <> chunk(wire) <> "0\r\n\r\n"
      server = start_server(provider, [first, second])

      trace = fn event ->
        send(owner, {:trace, event})

        case event do
          %{type: :request, ids: %{wire_attempt: 1}} ->
            Agent.update(clock, fn _ -> @milestones["prefix"] end)

          %{type: :request, ids: %{wire_attempt: 2}} ->
            Agent.update(clock, fn _ -> @milestones["frame"] end)

          %{type: :response_data, ids: %{wire_attempt: 2}} ->
            Agent.update(clock, fn _ -> @milestones["terminal"] end)

          _ ->
            :ok
        end
      end

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            base_delay: 0,
            trace_observer: trace,
            admission: fn _ ->
              Agent.update(clock, fn _ -> @milestones["admission"] end)
              :allow
            end
          ]
        )

      stream = invoke(provider, @route, config, owner)
      Agent.update(clock, fn _ -> @milestones["dispatch"] end)
      events = Enum.to_list(stream)
      assert [terminal] = Enum.filter(events, &terminal?/1)
      assert metrics(terminal) == expected_metrics("content", 80)
      assert [{:completed, _}] = [terminal]
      assert [one, two] = GenServer.call(server, :requests)
      assert one == two
      assert_receive {:trace, %{type: :request, ids: first_ids}}
      assert_receive {:trace, %{type: :request, ids: second_ids}}
      assert first_ids.logical_request_id == second_ids.logical_request_id
      refute first_ids.attempt_id == second_ids.attempt_id
      assert first_ids.wire_attempt == 1
      assert second_ids.wire_attempt == 2
      assert_receive {:wire_request, ^one}
      assert_receive {:wire_request, ^two}
      refute_receive {:wire_request, _}, 0
    end
  end

  for provider <- [:openai, :ollama, :omlx], route <- [:broker_legacy, :session] do
    @provider provider
    @route route
    @tag :first_token_contract
    test "#{provider} #{route} tool continuation starts a fresh clock and executes once", %{
      clock: clock
    } do
      provider = @provider
      owner = self()

      call = %{
        "index" => 0,
        "id" => "t1",
        "type" => "function",
        "function" => %{"name" => "count", "arguments" => "{}"}
      }

      first_wire =
        Contract.frame(provider, %{"tool_calls" => [call]}) <> Contract.terminal(provider)

      second_wire =
        Contract.frame(provider, %{"content" => "answer"}) <> Contract.terminal(provider)

      response = fn wire -> Contract.headers() <> chunk(wire) <> "0\r\n\r\n" end
      server = start_server(provider, [response.(first_wire), response.(second_wire)])
      counter = start_supervised!({Agent, fn -> 0 end}, id: :request_counter)

      trace = fn
        %{type: :request} = event ->
          attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
          send(owner, {:request_trace, event})

          Agent.update(clock, fn _ ->
            if attempt == 1, do: @milestones["frame"], else: @milestones["continuation_frame"]
          end)

        %{type: :response_data} ->
          attempt = Agent.get(counter, & &1)

          Agent.update(clock, fn _ ->
            if attempt == 1,
              do: @milestones["terminal"],
              else: @milestones["continuation_terminal"]
          end)

        _ ->
          :ok
      end

      config = CompletionConfig.new(recovery: [trace_observer: trace])
      tool = %Mojentic.TestSupport.CountingTool{owner: owner}
      broker = Broker.new("gpt-4o", gateway(provider))

      {stream, handle} =
        case @route do
          :broker_legacy ->
            {Broker.generate_stream(broker, [Message.user("hello")], [tool], config), nil}

          :session ->
            session = ChatSession.new(broker, system_prompt: "system", tools: [tool])

            {:ok, stream, handle} =
              ChatSession.send_stream(session, "hello", recovery: config.recovery)

            {stream, handle}
        end

      Agent.update(clock, fn _ -> @milestones["dispatch"] end)
      events = Enum.to_list(stream)
      assert [first_terminal, second_terminal] = Enum.filter(events, &terminal?/1)
      assert metrics(first_terminal) == expected_metrics("tool_call", 80)
      assert metrics(second_terminal) == expected_metrics("content", 50)
      assert_receive {:tool_executed, %{}}
      refute_receive {:tool_executed, _}, 0
      assert [one, two] = GenServer.call(server, :requests)
      [_, first_body] = String.split(one, "\r\n\r\n", parts: 2)
      [_, second_body] = String.split(two, "\r\n\r\n", parts: 2)
      initial = Jason.decode!(first_body)
      followup = Jason.decode!(second_body)
      assert Map.drop(initial, ["messages"]) == Map.drop(followup, ["messages"])
      assert Enum.take(followup["messages"], length(initial["messages"])) == initial["messages"]

      assert [
               %{"role" => "assistant", "tool_calls" => [_]},
               %{"role" => "tool", "content" => "\"tool-result-secret\""}
             ] = Enum.drop(followup["messages"], length(initial["messages"]))

      assert_receive {:request_trace, first_trace}
      assert_receive {:request_trace, second_trace}
      refute first_trace.ids.logical_request_id == second_trace.ids.logical_request_id
      assert first_trace.ids.wire_attempt == 1
      assert second_trace.ids.wire_attempt == 1

      if handle do
        session = ChatSession.finalize_stream(handle)
        assert List.last(ChatSession.messages(session)).message.content == "answer"
      end
    end
  end

  test "frozen v1 and additive v2 executable references retain their source identities" do
    for {version, hash} <- [
          {"v1", "e94d4f53928b3ea519eceedcb0f7e7a41ae2eb5da52076369d92374108b3d2a8"},
          {"v2", "9b64e037af8ee375a6344b94f4f66992f867357a32b8db360042a8eff4f12eca"}
        ] do
      source = File.read!("test/contracts/reference/ts-stream-first-token-#{version}.test.ts")
      assert Base.encode16(:crypto.hash(:sha256, source), case: :lower) == hash
    end

    assert Contract.contract()["version"] == "ex-stream-first-token-v1"

    assert Contract.contract()["reference"]["sha256"] ==
             "9b64e037af8ee375a6344b94f4f66992f867357a32b8db360042a8eff4f12eca"

    assert Contract.contract()["reference"]["commit"] ==
             "54171796a2b02c0f0170d0758d2e3c693ad027c9"
  end

  for provider <- [:openai, :ollama, :omlx],
      route <- [:events, :legacy, :broker_events, :broker_legacy, :session],
      recovery <- [nil, []] do
    @provider provider
    @route route
    @recovery recovery
    @tag :first_token_contract
    test "#{provider} #{route} recovery #{inspect(recovery)} retains first-token timing on disconnect without replay",
         %{clock: clock} do
      provider = @provider
      server = start_server(provider, [{:stream_hold, Contract.headers()}])
      stream = invoke(provider, @route, CompletionConfig.new(recovery: @recovery), self())
      Agent.update(clock, fn _ -> @milestones["dispatch"] end)
      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          stream
          |> Stream.map(fn event ->
            if event == {:content, "answer"} or event == "answer",
              do: Agent.update(clock, fn _ -> @milestones["terminal"] end)

            event
          end)
          |> Enum.to_list()
        end)

      assert_receive {:held_response_sent, _request, _response}, 3000
      Agent.update(clock, fn _ -> @milestones["frame"] end)

      :ok =
        GenServer.call(
          server,
          {:release, chunk(Contract.frame(provider, %{"content" => "answer"}))}
        )

      events = Task.await(task)
      assert [terminal] = Enum.filter(events, &terminal?/1)
      assert {:error, _} = terminal
      assert List.last(events) == terminal
      assert metrics(terminal) == expected_metrics("content", 80)
      assert_request(server, provider, @route)
      if @route == :session, do: assert_receive({:session_final, {:error, _}})
    end
  end

  for provider <- [:openai, :ollama, :omlx], recovery <- [nil, []] do
    @provider provider
    @recovery recovery
    @tag :first_token_contract
    test "#{provider} recovery #{inspect(recovery)} HTTP rejection has duration without a first token",
         %{clock: clock} do
      # Even a body shaped like provider frames is HTTP error evidence, not output.
      body = Contract.frame(@provider, %{"content" => "uncaptured"})
      server = start_server(@provider, [:hold])
      stream = invoke(@provider, :events, CompletionConfig.new(recovery: @recovery), self())
      Agent.update(clock, fn _ -> @milestones["dispatch"] end)
      supervisor = start_supervised!(Task.Supervisor)
      task = Task.Supervisor.async_nolink(supervisor, fn -> Enum.to_list(stream) end)
      assert_receive {:wire_request, request}, 3000
      send(self(), {:wire_request, request})
      Agent.update(clock, fn _ -> @milestones["terminal"] end)

      :ok =
        GenServer.call(
          server,
          {:release,
           "HTTP/1.1 403 Forbidden\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
             body}
        )

      assert [{:error, _} = terminal] = Task.await(task)
      assert metrics(terminal) == %{request_duration_ms: 80}
      assert_request(server, @provider, :events)
    end
  end

  for provider <- [:openai, :ollama, :omlx] do
    @provider provider
    @tag :first_token_contract
    test "#{provider} default session forwards timing and finalizes successful history", %{
      clock: clock
    } do
      server = start_server(@provider, [{:stream_hold, Contract.headers()}])
      session = ChatSession.new(Broker.new("gpt-4o", gateway(@provider)), system_prompt: "system")
      {:ok, stream, handle} = ChatSession.send_stream(session, "hello")
      Agent.update(clock, fn _ -> @milestones["dispatch"] end)
      supervisor = start_supervised!(Task.Supervisor)
      task = Task.Supervisor.async_nolink(supervisor, fn -> Enum.to_list(stream) end)
      assert_receive {:held_response_sent, _request, _response}, 3000
      Agent.update(clock, fn _ -> @milestones["frame"] end)
      wire = Contract.frame(@provider, %{"content" => "answer"}) <> Contract.terminal(@provider)
      :ok = GenServer.call(server, {:release, chunk(wire) <> "0\r\n\r\n"})
      assert ["answer", {:completed, _} = terminal] = Task.await(task)
      assert metrics(terminal) == expected_metrics("content", 25)
      final = ChatSession.finalize_stream(handle)

      assert Enum.map(ChatSession.messages(final), & &1.message.role) == [
               :system,
               :user,
               :assistant
             ]

      assert List.last(ChatSession.messages(final)).message.content == "answer"
      assert_request(server, @provider, :session)
    end
  end

  for provider <- [:openai, :omlx], mode <- [:events, :legacy] do
    @provider provider
    @mode mode
    @tag :first_token_contract
    test "#{provider} #{mode} legacy argument observation prevents resend after disconnect", %{
      clock: clock
    } do
      owner = self()
      server = start_server(@provider, [{:stream_hold, Contract.headers()}])

      config =
        CompletionConfig.new(
          recovery: [
            max_attempts: 2,
            admission: fn _ ->
              send(owner, :admitted)
              :allow
            end,
            trace_observer: fn
              %{type: :response_data} -> Agent.update(clock, fn _ -> @milestones["terminal"] end)
              _ -> :ok
            end
          ]
        )

      stream = invoke(@provider, @mode, config, owner)
      Agent.update(clock, fn _ -> @milestones["dispatch"] end)
      supervisor = start_supervised!(Task.Supervisor)
      task = Task.Supervisor.async_nolink(supervisor, fn -> Enum.to_list(stream) end)
      assert_receive {:held_response_sent, _request, _response}, 3000
      Agent.update(clock, fn _ -> @milestones["frame"] end)
      frame = Contract.frame(@provider, %{"function_call" => %{"arguments" => "{"}})
      :ok = GenServer.call(server, {:release, chunk(frame)})
      assert [{:error, %CompletionError{} = error} = terminal] = Task.await(task)
      assert metrics(terminal) == expected_metrics("tool_call", 80)
      assert error.progress.observed.tool_fragments == 1
      assert error.progress.delivered.completed_tool_calls == 0
      refute error.retry_eligible
      assert error.reason == :stream_interrupted
      assert_request(server, @provider, @mode)
      refute_receive :admitted, 0
    end
  end

  @tag :first_token_eof_proof
  test "Ollama final frame without newline retains observation before rejected capture", %{
    clock: clock
  } do
    eof_capture_probe(:events, :rejected, clock)
  end

  for route <- [:events, :legacy, :broker_events, :broker_legacy, :session],
      outcome <- [:delayed, :rejected, :cancelled] do
    @route route
    @outcome outcome
    @tag :first_token_contract
    test "Ollama #{@route} split final frame without newline through #{@outcome} end capture", %{
      clock: clock
    } do
      eof_capture_probe(@route, @outcome, clock)
    end
  end

  for route <- [:events, :broker_events] do
    @route route
    @tag :first_token_contract
    test "Ollama #{@route} final frame without newline preserves timing and provider metrics without recovery",
         %{clock: clock} do
      server = start_server(:ollama, [{:stream_hold, Contract.headers()}])
      stream = invoke(:ollama, @route, CompletionConfig.new(), self())
      Agent.update(clock, fn _ -> @milestones["dispatch"] end)

      stream =
        Stream.map(stream, fn
          {:content, "answer"} = event ->
            Agent.update(clock, fn _ -> @milestones["terminal"] end)
            event

          event ->
            event
        end)

      task = collect_async(stream)
      assert_receive {:held_response_sent, _, _}, 3000
      Agent.update(clock, fn _ -> @milestones["frame"] end)
      frame = Jason.encode!(Contract.contract()["eof_frame"])
      :ok = GenServer.call(server, {:release, chunk(frame) <> "0\r\n\r\n"})
      events = Task.await(task)
      assert [{:content, "answer"}, {:completed, _}] = events
      terminal = assert_terminal_timing(events, expected_metrics("thinking", 80))
      assert_provider_metrics(terminal, :ollama)
      assert_request(server, :ollama, @route)
    end
  end

  defp eof_capture_probe(route, outcome, clock) do
    owner = self()
    frame = Jason.encode!(Contract.contract()["eof_frame"])
    split = byte_size(frame) - 4
    <<prefix::binary-size(split), rest::binary>> = frame
    server = start_server(:ollama, [{:stream_hold, Contract.headers() <> chunk(prefix)}])
    cancel = make_ref()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          cancel_ref: cancel,
          trace_observer: eof_trace(owner, prefix, clock),
          observer: fn %{type: type} ->
            if type == :attempt_started, do: send(owner, {:eof_owner, self()})
          end,
          admission: fn _ ->
            send(owner, :admitted)
            :allow
          end
        ]
      )

    stream = invoke(:ollama, route, config, owner)
    Agent.update(clock, fn _ -> @milestones["dispatch"] end)
    task = collect_async(stream, owner)
    assert_receive {:eof_owner, recovery_owner}, 3000
    assert_receive :eof_prefix_captured, 3000
    Agent.update(clock, fn _ -> @milestones["frame"] end)
    :ok = GenServer.call(server, {:release, chunk(rest) <> "0\r\n\r\n"})
    assert_receive {:eof_capture_waiting, worker}, 3000
    refute_receive {:delivered, _}, 0
    Agent.update(clock, fn _ -> @milestones["terminal"] end)

    case outcome do
      :delayed -> send(worker, :release)
      :rejected -> send(worker, :reject)
      :cancelled -> send(recovery_owner, {:cancel, cancel})
    end

    events = Task.await(task)
    terminal = assert_terminal_timing(events, expected_metrics("thinking", 80))
    if outcome == :delayed, do: assert_provider_metrics(terminal, :ollama)
    assert_capture_outcome(events, route, outcome)
    refute_receive :admitted, 0
    assert_request(server, :ollama, route)
  end

  defp eof_trace(owner, prefix, clock) do
    fn
      %{type: :request} ->
        Agent.update(clock, fn _ -> @milestones["prefix"] end)

      %{type: :response_data, body: ^prefix} ->
        send(owner, :eof_prefix_captured)
        :ok

      %{type: :response_end, outcome: :complete} ->
        send(owner, {:eof_capture_waiting, self()})

        receive do
          :release -> :ok
          :reject -> {:error, :rejected}
        end

      _ ->
        :ok
    end
  end

  defp capture_probe(provider, route, row, outcome, clock) do
    owner = self()
    token = Contract.frame(provider, row["delta"])
    split = byte_size(token) - 4
    <<part::binary-size(split), rest::binary>> = token
    prefix = Contract.prefix(provider) <> part
    server = start_server(provider, [{:stream_hold, Contract.headers() <> chunk(prefix)}])
    cancel = make_ref()

    trace = capture_trace(owner, prefix, clock)

    recovery = [
      max_attempts: 2,
      cancel_ref: cancel,
      trace_observer: trace,
      admission: fn _ ->
        send(owner, :admitted)
        :allow
      end,
      observer: fn %{type: type} ->
        if type == :attempt_started, do: send(owner, {:recovery_owner, self()})
      end
    ]

    config = CompletionConfig.new(recovery: recovery)
    stream = invoke(provider, route, config, owner)
    # Construction occurs at 10; enumeration dispatches at 100.
    assert GenServer.call(server, :requests) == []
    Agent.update(clock, fn _ -> @milestones["dispatch"] end)
    task = collect_async(stream, owner)
    assert_receive {:recovery_owner, recovery_owner}, 3000
    assert_receive :prefix_captured, 3000
    Agent.update(clock, fn _ -> @milestones["frame"] end)

    :ok =
      GenServer.call(
        server,
        {:release,
         chunk(rest <> later_frame(provider, row) <> Contract.terminal(provider)) <> "0\r\n\r\n"}
      )

    assert_receive {:capture_waiting, worker}, 3000
    task_ref = task.ref
    refute_receive {^task_ref, _}, 0
    refute_receive {:delivered, _}, 0
    Agent.update(clock, fn _ -> @milestones["terminal"] end)

    case outcome do
      :delayed -> send(worker, :release)
      :rejected -> send(worker, :reject)
      :cancelled -> send(recovery_owner, {:cancel, cancel})
    end

    events = Task.await(task, 5000)
    assert_terminal_timing(events, expected_metrics(row["kind"], 80))

    if outcome == :delayed, do: assert_provider_metrics(List.last(events), provider)
    assert_capture_outcome(events, route, outcome)

    assert_request(server, provider, route)
    refute_receive :admitted, 0
  end

  defp capture_trace(owner, prefix, clock) do
    fn
      %{type: :request} ->
        Agent.update(clock, fn _ -> @milestones["prefix"] end)

      %{type: :response_data, body: ^prefix} ->
        send(owner, :prefix_captured)
        :ok

      %{type: :response_data} ->
        send(owner, {:capture_waiting, self()})

        receive do
          :release -> :ok
          :reject -> {:error, :rejected}
        end

      _ ->
        :ok
    end
  end

  defp assert_capture_outcome(events, route, outcome) do
    if outcome != :delayed do
      refute_receive {:delivered, _}, 0

      semantic_events =
        Enum.reject(events, fn
          {:content, ""} -> true
          {kind, _} when kind in [:progress, :metrics] -> true
          _ -> false
        end)

      assert [{:error, %CompletionError{} = error}] = semantic_events
      refute error.progress.delivered.content
      refute error.progress.delivered.reasoning
      assert error.progress.delivered.completed_tool_calls == 0
      assert length(error.history) == 1
      refute inspect(error) =~ "answer"
      refute Jason.encode!(error) =~ "thought"
      if outcome == :rejected, do: assert(error.reason == :capture_failed)
    end

    if route == :session do
      assert_receive {:session_final, final}
      if outcome != :delayed, do: assert(match?({:error, %CompletionError{}}, final))
    end
  end

  defp untraced_probe(provider, route, row, clock) do
    server = start_server(provider, [{:stream_hold, Contract.headers()}])
    stream = invoke(provider, route, CompletionConfig.new(), self())
    assert GenServer.call(server, :requests) == []
    Agent.update(clock, fn _ -> @milestones["dispatch"] end)
    task = collect_async(stream)
    assert_receive {:held_response_sent, _request, _response}, 3000
    Agent.update(clock, fn _ -> @milestones["frame"] end)

    wire =
      Contract.prefix(provider) <>
        Contract.frame(provider, row["delta"]) <>
        later_frame(provider, row) <> Contract.terminal(provider)

    :ok = GenServer.call(server, {:release, chunk(wire) <> "0\r\n\r\n"})
    events = Task.await(task, 5000)
    assert [terminal] = Enum.filter(events, &terminal?/1)
    assert List.last(events) == terminal
    assert metrics(terminal) == expected_metrics(row["kind"], 25)
    assert_provider_metrics(terminal, provider)
    assert_request(server, provider, route)
  end

  defp start_server(provider, responses) do
    server = start_supervised!({ScriptedCompletionServer, {self(), responses, 0, 1}})
    assert_receive {:server_port, port}
    host = "http://127.0.0.1:#{port}"

    case provider do
      :openai ->
        System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
        System.put_env("OPENAI_API_KEY", "contract-key")

      :ollama ->
        System.put_env("OLLAMA_HOST", host)

      :omlx ->
        System.put_env("OMLX_HOST", host)
        System.put_env("OMLX_API_KEY", "contract-key")
    end

    server
  end

  defp gateway(:openai), do: OpenAI
  defp gateway(:ollama), do: Ollama
  defp gateway(:omlx), do: OMLX

  defp invoke(provider, :events, config, _owner),
    do: gateway(provider).complete_stream_events("gpt-4o", [Message.user("hello")], config)

  defp invoke(provider, :legacy, config, _owner),
    do: gateway(provider).complete_stream("gpt-4o", [Message.user("hello")], nil, config)

  defp invoke(provider, :broker_events, config, _owner),
    do:
      Broker.generate_stream_events(
        Broker.new("gpt-4o", gateway(provider)),
        [Message.user("hello")],
        config
      )

  defp invoke(provider, :broker_legacy, config, _owner),
    do:
      Broker.generate_stream(
        Broker.new("gpt-4o", gateway(provider)),
        [Message.user("hello")],
        nil,
        config
      )

  defp invoke(provider, :session, config, owner) do
    session = ChatSession.new(Broker.new("gpt-4o", gateway(provider)), system_prompt: "system")

    {:ok, stream, handle} =
      ChatSession.send_stream(session, "hello", config |> Map.from_struct() |> Enum.to_list())

    Stream.concat(
      stream,
      Stream.flat_map([:finalize], fn _ ->
        send(owner, {:session_final, ChatSession.finalize_stream(handle)})
        []
      end)
    )
  end

  defp later_frame(_provider, %{"kind" => nil}), do: ""

  defp later_frame(provider, _row),
    do: Contract.frame(provider, %{"content" => "later", "thinking" => "later thought"})

  defp assert_provider_metrics({:completed, evidence}, :ollama) do
    assert evidence.metadata["total_duration"] == 900
    assert evidence.metadata["prompt_eval_duration"] == 200
    assert evidence.provider_model == "fixture-model"
  end

  defp assert_provider_metrics({:completed, evidence}, _provider) do
    assert evidence.usage["time_to_first_token"] == 0.7
    assert evidence.usage["total_tokens"] == 5
    assert evidence.provider_model == "fixture-model"
  end

  defp assert_provider_metrics({:error, _}, _provider), do: :ok

  defp assert_terminal_timing(events, expected) do
    assert [terminal] = Enum.filter(events, &terminal?/1)
    assert List.last(events) == terminal
    assert metrics(terminal) == expected
    terminal
  end

  defp collect_async(stream, owner \\ nil) do
    supervisor = start_supervised!(Task.Supervisor)

    Task.Supervisor.async_nolink(supervisor, fn ->
      stream
      |> Stream.each(fn item ->
        if owner && output?(item), do: send(owner, {:delivered, item})
      end)
      |> Enum.to_list()
    end)
  end

  defp output?({kind, text}) when kind in [:content, :thinking] and is_binary(text),
    do: byte_size(text) > 0

  defp output?({:tool_calls, [_ | _]}), do: true
  defp output?(text) when is_binary(text), do: byte_size(text) > 0
  defp output?(_), do: false

  defp terminal?({kind, _}), do: kind in [:completed, :error]
  defp terminal?(_), do: false

  defp metrics({:completed, evidence}),
    do:
      Map.take(evidence.metadata, [
        :time_to_first_token_ms,
        :first_token_kind,
        :request_duration_ms
      ])

  defp metrics({:error, %CompletionError{metadata: metadata}}), do: metadata
  defp metrics({:error, {:stream_error, _, evidence}}), do: evidence.metadata

  defp metrics({:error, {_kind, evidence}}),
    do:
      Map.take(evidence.metadata, [
        :time_to_first_token_ms,
        :first_token_kind,
        :request_duration_ms
      ])

  defp expected_metrics(nil, duration), do: %{request_duration_ms: duration}

  defp expected_metrics(kind, duration),
    do: %{
      time_to_first_token_ms: 25,
      first_token_kind: String.to_existing_atom(kind),
      request_duration_ms: duration
    }

  defp assert_request(server, provider, route) do
    assert [request] = GenServer.call(server, :requests)
    path = if provider == :ollama, do: "/api/chat", else: "/v1/chat/completions"
    assert String.starts_with?(request, "POST #{path} HTTP/1.1\r\n")
    [headers, body] = String.split(request, "\r\n\r\n", parts: 2)

    if provider != :ollama,
      do: assert(String.downcase(headers) =~ "authorization: bearer contract-key")

    messages =
      if route == :session,
        do: [
          %{"role" => "system", "content" => "system"},
          %{"role" => "user", "content" => "hello"}
        ],
        else: [%{"role" => "user", "content" => "hello"}]

    expected = %{"model" => "gpt-4o", "messages" => messages, "stream" => true}
    expected = if provider == :ollama, do: Map.put(expected, "options", %{}), else: expected

    expected =
      if provider != :ollama and route in [:events, :broker_events],
        do: Map.put(expected, "stream_options", %{"include_usage" => true}),
        else: expected

    assert Jason.decode!(body) == expected
    assert_receive {:wire_request, ^request}
    refute_receive {:wire_request, _}, 0
  end

  defp chunk(data), do: Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"
end
