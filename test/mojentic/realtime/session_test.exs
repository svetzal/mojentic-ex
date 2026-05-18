defmodule Mojentic.Realtime.SessionTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.Realtime.Config
  alias Mojentic.Realtime.Event
  alias Mojentic.Realtime.Session

  # ---------------------------------------------------------------------------
  # Fake transport — a simple GenServer that records sent payloads
  # and lets tests push inbound messages directly.
  # ---------------------------------------------------------------------------

  defmodule FakeTransport do
    @behaviour Mojentic.Realtime.Transport

    use GenServer

    @impl Mojentic.Realtime.Transport
    def connect(_url, _headers, _opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl Mojentic.Realtime.Transport
    def send(pid, payload), do: GenServer.call(pid, {:send, payload})

    @impl Mojentic.Realtime.Transport
    def close(pid) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
    end

    @impl Mojentic.Realtime.Transport
    def subscribe(pid, subscriber), do: GenServer.call(pid, {:subscribe, subscriber})

    # Push a raw inbound event to the subscribed process.
    def push(pid, msg), do: GenServer.call(pid, {:push, msg})

    # Return all payloads sent to this transport.
    def sent_payloads(pid), do: GenServer.call(pid, :sent_payloads)

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

    def handle_call(:sent_payloads, _from, state) do
      {:reply, state.sent, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Helper tool for tool-dispatch tests.
  # ---------------------------------------------------------------------------

  defmodule GreetTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
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
    {:ok, transport_pid} = FakeTransport.connect("ws://fake", [], [])

    config =
      Keyword.get(opts, :config, Config.new(modalities: [:text], turn_detection: :none))

    session_opts =
      [
        transport: transport_pid,
        transport_module: FakeTransport,
        config: config
      ] ++ Keyword.drop(opts, [:config])

    {:ok, session_pid} = Session.start_link(session_opts)
    {session_pid, transport_pid}
  end

  defp push(transport_pid, type, extra \\ %{}) do
    FakeTransport.push(transport_pid, {:realtime_message, Map.merge(%{"type" => type}, extra)})
  end

  defp collect_events(timeout \\ 100) do
    collect_events([], timeout)
  end

  defp collect_events(acc, timeout) do
    receive do
      {:realtime_event, event} -> collect_events([event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "subscribe/1" do
    test "subscriber receives realtime_event messages" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "session.updated")

      events = collect_events()

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

      events = collect_events()
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

      events = collect_events()
      assert Enum.any?(events, &match?(%Event{kind: :interrupted}, &1))

      Session.close(session)
    end

    test "is a no-op when no turn is active" do
      {session, _transport} = start_session()
      :ok = Session.subscribe(session)

      assert :ok = Session.interrupt(session)

      events = collect_events(50)
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

      events = collect_events()
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

      events = collect_events()
      assert Enum.any?(events, &match?(%Event{kind: :interrupted}, &1))

      Session.close(session)
    end

    test "rate_limits.updated emits rate_limited event" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      push(transport, "rate_limits.updated", %{
        "rate_limits" => [%{"reset_seconds" => 2}]
      })

      events = collect_events()
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

      events = collect_events()
      ev = Enum.find(events, &match?(%Event{kind: :error}, &1))

      assert ev
      refute ev.payload.recoverable?

      Session.close(session)
    end

    test "realtime_close stops the session" do
      {session, transport} = start_session()
      :ok = Session.subscribe(session)

      FakeTransport.push(transport, {:realtime_close, :server})

      # Give the GenServer time to process the stop
      Process.sleep(50)

      refute Process.alive?(session)
    end
  end

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

      # Wait for the async batch to complete
      Process.sleep(200)

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

      Process.sleep(200)

      events = collect_events()
      kinds = Enum.map(events, & &1.kind)

      assert :tool_call_dispatched in kinds
      assert :tool_call_completed in kinds

      Session.close(session)
    end

    test "interrupted turn with :drop policy discards tool outputs" do
      config =
        Config.new(
          modalities: [:text],
          turn_detection: :none,
          tools: [GreetTool],
          on_interrupt: :drop
        )

      {session, transport} = start_session(config: config)
      :ok = Session.subscribe(session)

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

      # Interrupt before batch completes
      :ok = Session.interrupt(session)

      Process.sleep(200)

      payloads = FakeTransport.sent_payloads(transport)

      output_payload =
        Enum.find(payloads, fn p ->
          p["type"] == "conversation.item.create" &&
            get_in(p, ["item", "type"]) == "function_call_output"
        end)

      assert is_nil(output_payload),
             "Expected no function_call_output but found: #{inspect(output_payload)}"

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
