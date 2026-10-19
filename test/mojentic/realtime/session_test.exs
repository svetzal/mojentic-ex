defmodule Mojentic.Realtime.SessionTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.Realtime.Config
  alias Mojentic.Realtime.Event
  alias Mojentic.Realtime.Session

  # Failure bound for asynchronous delivery, termination and transport cleanup.
  @shutdown_bound 2_000

  # ---------------------------------------------------------------------------
  # Fake transport — a simple GenServer that records sent payloads
  # and lets tests push inbound messages directly.
  # ---------------------------------------------------------------------------

  defmodule FakeTransport do
    @behaviour Mojentic.Realtime.Transport

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl Mojentic.Realtime.Transport
    def connect(_url, _headers, _opts), do: start_link(:ok)

    @impl Mojentic.Realtime.Transport
    def send(pid, payload), do: GenServer.call(pid, {:send, payload})

    @impl Mojentic.Realtime.Transport
    def close(pid) do
      if Process.alive?(pid), do: GenServer.call(pid, :close), else: :ok
    end

    @impl Mojentic.Realtime.Transport
    def subscribe(pid, subscriber), do: GenServer.call(pid, {:subscribe, subscriber})

    # Push a raw inbound event to the subscribed process.
    def push(pid, msg), do: GenServer.call(pid, {:push, msg})

    # Return all payloads sent to this transport.
    def sent_payloads(pid), do: GenServer.call(pid, :sent_payloads)

    def hold_cleanup(pid), do: GenServer.call(pid, {:hold_cleanup, self()})

    def release_cleanup(pid), do: GenServer.call(pid, :release_cleanup)

    @impl GenServer
    def init(:ok), do: {:ok, %{subscriber: nil, sent: []}}

    @impl GenServer
    def handle_call({:subscribe, pid}, _from, state) do
      {:reply, :ok, %{state | subscriber: pid}}
    end

    def handle_call({:send, payload}, _from, state) do
      {:reply, :ok, %{state | sent: state.sent ++ [payload]}}
    end

    def handle_call({:push, msg}, _from, state) do
      if state.subscriber, do: Kernel.send(state.subscriber, msg)
      {:reply, :ok, state}
    end

    def handle_call({:hold_cleanup, observer}, _from, state) do
      {:reply, :ok, Map.put(state, :cleanup, %{observer: observer})}
    end

    def handle_call(:close, {session, _tag} = caller, %{cleanup: cleanup} = state) do
      Kernel.send(cleanup.observer, {:cleanup_started, session, self()})
      {:noreply, %{state | cleanup: Map.put(cleanup, :caller, caller)}}
    end

    def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}

    def handle_call(:release_cleanup, _from, %{cleanup: cleanup} = state) do
      {session, _tag} = cleanup.caller
      Kernel.send(cleanup.observer, {:cleanup_completed, session, self()})
      GenServer.reply(cleanup.caller, :ok)
      {:stop, :normal, :ok, state}
    end

    def handle_call(:sent_payloads, _from, state) do
      {:reply, state.sent, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Helper tool for tool-dispatch tests.
  # ---------------------------------------------------------------------------

  defmodule GreetTool do
    @behaviour Mojentic.LLM.Tools.Tool

    defstruct [:owner]

    @impl true
    def run(%__MODULE__{owner: owner}, args) when is_pid(owner) do
      send(owner, {:greet_started, self()})

      receive do
        :release -> run(__MODULE__, args)
      end
    end

    def run(_tool, args), do: {:ok, %{greeting: "Hello, #{Map.get(args, "name", "world")}!"}}

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "greet",
          description: "Greet someone",
          parameters: %{
            type: "object",
            properties: %{name: %{type: "string"}},
            required: ["name"]
          }
        }
      }
    end
  end

  defmodule CancellableTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, _args), do: {:ok, %{result: "ran"}}

    def run(_tool, _args, %RunContext{} = ctx) do
      if RunContext.cancelled?(ctx) do
        {:error, :cancelled}
      else
        {:ok, %{result: "ran"}}
      end
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "cancellable",
          description: "Supports cancellation",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Setup helper
  # ---------------------------------------------------------------------------

  defp start_session(opts \\ []) do
    transport_pid = start_supervised!({FakeTransport, :ok})

    config =
      Keyword.get(opts, :config, Config.new(modalities: [:text], turn_detection: :none))

    session_opts =
      [
        transport: transport_pid,
        transport_module: FakeTransport,
        config: config
      ] ++ Keyword.drop(opts, [:config])

    session_pid =
      start_supervised!(Supervisor.child_spec({Session, session_opts}, restart: :temporary))

    {session_pid, transport_pid}
  end

  defp push(transport_pid, type, extra \\ %{}) do
    FakeTransport.push(transport_pid, {:realtime_message, Map.merge(%{"type" => type}, extra)})
  end

  defp collect_events(session) do
    _ = :sys.get_state(session)
    drain_events([])
  end

  defp drain_events(acc) do
    receive do
      {:realtime_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "subscribe/1" do
    test "subscriber receives realtime_event messages" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "session.updated")

      events = collect_events(session)

      assert Enum.any?(events, &match?(%Event{kind: :session_updated}, &1))

      Session.close(session)
    end
  end

  describe "initialise/1" do
    test "sends session.update to transport and emits session_opened" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)
      :ok = Session.initialise(session)

      payloads = FakeTransport.sent_payloads(transport)
      assert Enum.any?(payloads, &match?(%{"type" => "session.update"}, &1))

      events = collect_events(session)
      assert Enum.any?(events, &match?(%Event{kind: :session_opened}, &1))

      Session.close(session)
    end
  end

  describe "send_text/2" do
    test "sends conversation.item.create and response.create" do
      {session, transport} = start_session()
      :ok = Session.send_text(session, "Hello")

      payloads = FakeTransport.sent_payloads(transport)
      types = Enum.map(payloads, & &1["type"])

      assert "conversation.item.create" in types
      assert "response.create" in types

      Session.close(session)
    end
  end

  describe "commit_audio/1" do
    test "sends audio commit and response.create" do
      {session, transport} = start_session()
      :ok = Session.commit_audio(session)

      payloads = FakeTransport.sent_payloads(transport)
      types = Enum.map(payloads, & &1["type"])

      assert "input_audio_buffer.commit" in types
      assert "response.create" in types

      Session.close(session)
    end
  end

  describe "interrupt/1" do
    test "emits interrupted event when a turn is active" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "response.created", %{"response" => %{"id" => "r1"}})

      :ok = Session.interrupt(session)

      events = collect_events(session)
      assert Enum.any?(events, &match?(%Event{kind: :interrupted}, &1))

      Session.close(session)
    end

    test "is a no-op when no turn is active" do
      {session, _transport} = start_session()
      :ok = Session.subscribe(session)

      assert :ok = Session.interrupt(session)

      events = collect_events(session)
      refute Enum.any?(events, &match?(%Event{kind: :interrupted}, &1))

      Session.close(session)
    end
  end

  describe "update_instructions/2" do
    test "sends session.update with new instructions" do
      {session, transport} = start_session()
      :ok = Session.update_instructions(session, "Be terse.")

      payloads = FakeTransport.sent_payloads(transport)

      assert Enum.any?(payloads, fn p ->
               p["type"] == "session.update" &&
                 get_in(p, ["session", "instructions"]) == "Be terse."
             end)

      Session.close(session)
    end
  end

  describe "event normalisation" do
    test "speech_started emits user_speech_started" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "input_audio_buffer.speech_started", %{"audio_start_ms" => 250})

      events = collect_events(session)
      ev = Enum.find(events, &match?(%Event{kind: :user_speech_started}, &1))

      assert ev
      assert ev.payload.at_ms == 250

      Session.close(session)
    end

    test "speech_started cancels in-progress turn (barge-in)" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "response.created", %{"response" => %{"id" => "r1"}})
      push(transport, "input_audio_buffer.speech_started", %{"audio_start_ms" => 0})

      events = collect_events(session)
      assert Enum.any?(events, &match?(%Event{kind: :interrupted}, &1))

      Session.close(session)
    end

    test "rate_limits.updated emits rate_limited event" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "rate_limits.updated", %{
        "rate_limits" => [%{"reset_seconds" => 2}]
      })

      events = collect_events(session)
      ev = Enum.find(events, &match?(%Event{kind: :rate_limited}, &1))

      assert ev
      assert ev.payload.reset_ms == 2000

      Session.close(session)
    end

    test "error event with session_error type emits non-recoverable error" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "error", %{
        "error" => %{"type" => "session_error", "message" => "bad"}
      })

      events = collect_events(session)
      ev = Enum.find(events, &match?(%Event{kind: :error}, &1))

      assert ev
      refute ev.payload.recoverable?

      Session.close(session)
    end

    test "realtime_close stops the session" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      monitor = Process.monitor(session)
      transport_monitor = Process.monitor(transport)

      :ok = FakeTransport.hold_cleanup(transport)
      FakeTransport.push(transport, {:realtime_close, :server})

      assert_receive {:realtime_event,
                      %Event{kind: :session_closed, payload: %{reason: :server}}},
                     @shutdown_bound

      assert_receive {:cleanup_started, ^session, ^transport}, @shutdown_bound

      # The transport has accepted this exact session's close request without replying.
      # Reject that observed incomplete state immediately, without waiting for a DOWN.
      incomplete = %{
        session: session,
        transport: transport,
        delivered: :server_close,
        cleanup: :pending,
        session_exit: :pending,
        transport_exit: :pending
      }

      rejected = shutdown_probe(incomplete)

      :ok = FakeTransport.release_cleanup(transport)
      assert_receive {:cleanup_completed, ^session, ^transport}, @shutdown_bound

      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, @shutdown_bound
      assert_receive {:DOWN, ^transport_monitor, :process, ^transport, :normal}, @shutdown_bound

      completed = %{
        incomplete
        | cleanup: :completed,
          session_exit: {session, :normal},
          transport_exit: {transport, :normal}
      }

      assert :ok = shutdown_probe(completed)
      assert {:error, ^incomplete} = rejected
    end
  end

  defp shutdown_probe(observations) do
    IO.puts("shutdown boundary observations: #{inspect(observations, pretty: true)}")
    shutdown_result(observations)
  end

  defp shutdown_result(%{
         session: session,
         transport: transport,
         delivered: :server_close,
         cleanup: :completed,
         session_exit: {session, :normal},
         transport_exit: {transport, :normal}
       }),
       do: :ok

  defp shutdown_result(observations), do: {:error, observations}

  # Tool batches run in a background Task, so these events arrive asynchronously.
  # Under full-suite load they can exceed ExUnit's 100ms default. This bound only
  # caps how long a failure takes; each assertion still waits for the real message.
  @tool_task_bound 2_000

  describe "tool batch dispatch" do
    test "function_call items are executed and outputs submitted" do
      config = Config.new(modalities: [:text], turn_detection: :none, tools: [GreetTool])
      {session, transport} = start_session(config: config)
      :ok = Session.subscribe(session)

      # Simulate a complete response.done with a function call
      push(transport, "response.created", %{"response" => %{"id" => "r1"}})

      push(transport, "response.output_item.added", %{
        "response_id" => "r1",
        "item" => %{"type" => "function_call", "call_id" => "c1", "name" => "greet"}
      })

      push(transport, "response.function_call_arguments.done", %{
        "response_id" => "r1",
        "call_id" => "c1",
        "name" => "greet",
        "arguments" => ~s({"name":"Alice"})
      })

      push(transport, "response.done", %{"response" => %{"id" => "r1"}})

      assert_receive {:realtime_event,
                      %Event{kind: :tool_batch_submitted, payload: %{call_ids: ["c1"]}}},
                     @tool_task_bound

      _ = :sys.get_state(session)

      payloads = FakeTransport.sent_payloads(transport)
      types = Enum.map(payloads, & &1["type"])

      assert "conversation.item.create" in types
      assert "response.create" in types

      output_payload =
        Enum.find(payloads, fn p ->
          p["type"] == "conversation.item.create" &&
            get_in(p, ["item", "type"]) == "function_call_output"
        end)

      assert output_payload
      assert get_in(output_payload, ["item", "call_id"]) == "c1"

      Session.close(session)
    end

    test "tool_call_dispatched and tool_call_completed events reach subscribers" do
      config = Config.new(modalities: [:text], turn_detection: :none, tools: [GreetTool])
      {session, transport} = start_session(config: config)
      :ok = Session.subscribe(session)

      push(transport, "response.created", %{"response" => %{"id" => "r1"}})

      push(transport, "response.output_item.added", %{
        "response_id" => "r1",
        "item" => %{"type" => "function_call", "call_id" => "c2", "name" => "greet"}
      })

      push(transport, "response.function_call_arguments.done", %{
        "response_id" => "r1",
        "call_id" => "c2",
        "name" => "greet",
        "arguments" => ~s({"name":"Bob"})
      })

      push(transport, "response.done", %{"response" => %{"id" => "r1"}})

      assert_receive {:realtime_event,
                      %Event{kind: :tool_call_dispatched, payload: %{call_id: "c2"}}},
                     @tool_task_bound

      assert_receive {:realtime_event,
                      %Event{
                        kind: :tool_call_completed,
                        payload: %{call_id: "c2", result: %{greeting: "Hello, Bob!"}}
                      }},
                     @tool_task_bound

      assert_receive {:realtime_event,
                      %Event{kind: :tool_batch_submitted, payload: %{call_ids: ["c2"]}}},
                     @tool_task_bound

      Session.close(session)
    end

    test "interrupted turn with :drop policy discards tool outputs" do
      config =
        Config.new(
          modalities: [:text],
          turn_detection: :none,
          tools: [%GreetTool{owner: self()}],
          on_interrupt: :drop
        )

      {session, transport} = start_session(config: config)
      :ok = Session.subscribe(session)
      :erlang.trace(session, true, [:receive])

      push(transport, "response.created", %{"response" => %{"id" => "r2"}})

      push(transport, "response.output_item.added", %{
        "response_id" => "r2",
        "item" => %{"type" => "function_call", "call_id" => "c3", "name" => "greet"}
      })

      push(transport, "response.function_call_arguments.done", %{
        "response_id" => "r2",
        "call_id" => "c3",
        "name" => "greet",
        "arguments" => ~s({"name":"Carol"})
      })

      push(transport, "response.done", %{"response" => %{"id" => "r2"}})

      assert_receive {:greet_started, worker}, @tool_task_bound
      monitor = Process.monitor(worker)
      :ok = Session.interrupt(session)

      assert_receive {:realtime_event, %Event{kind: :interrupted, payload: %{turn_id: "r2"}}},
                     @tool_task_bound

      send(worker, :release)

      assert_receive {:realtime_event,
                      %Event{kind: :tool_call_completed, payload: %{call_id: "c3"}}},
                     @tool_task_bound

      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @tool_task_bound
      # Tool completion and worker exit precede delivery by the separate batch task.
      # Observe this call's actual batch receipt before issuing a public call: its
      # reply guarantees the batch handler, including output submission, finished.
      assert_receive {:trace, ^session, :receive,
                      {:tool_batch_done, [%{id: "c3", name: "greet", args: %{"name" => "Carol"}}],
                       [%{id: "c3", ok?: true, result: %{greeting: "Hello, Carol!"}}],
                       _duration}},
                     @tool_task_bound

      :ok = Session.subscribe(session)
      :erlang.trace(session, false, [:receive])

      payloads = FakeTransport.sent_payloads(transport)

      output_payload =
        Enum.find(payloads, fn p ->
          p["type"] == "conversation.item.create" &&
            get_in(p, ["item", "type"]) == "function_call_output" &&
            get_in(p, ["item", "call_id"]) == "c3"
        end)

      assert is_nil(output_payload),
             "Expected no function_call_output but found: #{inspect(output_payload)}"

      refute_received {:realtime_event,
                       %Event{
                         kind: :tool_batch_submitted,
                         payload: %{turn_id: "r2", call_ids: ["c3"]}
                       }}

      Session.close(session)
    end
  end

  describe "build_session_update/1" do
    test "produces a session.update payload with text modality" do
      config = Config.new(modalities: [:text], turn_detection: :none)
      payload = Session.build_session_update(config)

      assert payload["type"] == "session.update"
      assert get_in(payload, ["session", "output_modalities"]) == ["text"]
    end

    test "includes audio modality when configured" do
      config = Config.new(modalities: [:audio, :text])
      payload = Session.build_session_update(config)

      assert get_in(payload, ["session", "output_modalities"]) == ["audio"]
    end

    test "encodes server_vad turn detection" do
      config = Config.new(turn_detection: :server_vad)
      payload = Session.build_session_update(config)

      turn_detection = get_in(payload, ["session", "audio", "input", "turn_detection"])
      assert turn_detection["type"] == "server_vad"
    end

    test "sets turn_detection to nil for :none" do
      config = Config.new(turn_detection: :none)
      payload = Session.build_session_update(config)

      assert get_in(payload, ["session", "audio", "input", "turn_detection"]) == nil
    end

    test "includes tool definitions when tools are configured" do
      config = Config.new(tools: [GreetTool])
      payload = Session.build_session_update(config)

      tools = get_in(payload, ["session", "tools"])
      assert is_list(tools)
      assert length(tools) == 1
      assert hd(tools)["name"] == "greet"
    end

    test "encodes instructions when present" do
      config = Config.new(instructions: "Be helpful.")
      payload = Session.build_session_update(config)

      assert get_in(payload, ["session", "instructions"]) == "Be helpful."
    end
  end
end
