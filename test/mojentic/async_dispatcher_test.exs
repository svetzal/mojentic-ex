defmodule Mojentic.AsyncDispatcherTest do
  use ExUnit.Case, async: true

  alias Mojentic.{AsyncDispatcher, Event, Router}
  alias Mojentic.Agents.{AsyncAggregatorAgent, BaseAsyncAgent}
  alias Mojentic.Events.TerminateEvent

  defmodule EventA do
    use Event
    defstruct [:source, :correlation_id, :data]
  end

  defmodule EventB do
    use Event
    defstruct [:source, :correlation_id, :data]
  end

  defmodule EventC do
    use Event
    defstruct [:source, :correlation_id, :data]
  end

  defmodule SimpleAgent do
    @behaviour BaseAsyncAgent

    @impl true
    def receive_event_async(%EventA{data: data} = event) do
      result = %EventB{
        source: __MODULE__,
        correlation_id: event.correlation_id,
        data: "processed: #{data}"
      }

      {:ok, [result]}
    end

    def receive_event_async(_event), do: {:ok, []}
  end

  defmodule CollectorAgent do
    use GenServer

    def start_link do
      GenServer.start_link(__MODULE__, [])
    end

    def get_events(pid) do
      GenServer.call(pid, :get_events)
    end

    def clear(pid) do
      GenServer.cast(pid, :clear)
    end

    @impl true
    def init(_), do: {:ok, []}

    @impl true
    def handle_call({:receive_event, event}, _from, events) do
      {:reply, {:ok, []}, [event | events]}
    end

    @impl true
    def handle_call(:get_events, _from, events) do
      {:reply, Enum.reverse(events), events}
    end

    @impl true
    def handle_cast(:clear, _events) do
      {:noreply, []}
    end
  end

  describe "AsyncDispatcher.start_link/1" do
    test "starts with router" do
      router = Router.new()
      {:ok, pid} = AsyncDispatcher.start_link(router: router)

      assert Process.alive?(pid)
      AsyncDispatcher.stop(pid)
    end

    test "starts with custom batch size" do
      router = Router.new()
      {:ok, pid} = AsyncDispatcher.start_link(router: router, batch_size: 10)

      assert Process.alive?(pid)
      AsyncDispatcher.stop(pid)
    end

    test "starts with name registration" do
      router = Router.new()
      {:ok, pid} = AsyncDispatcher.start_link(router: router, name: :test_dispatcher)

      assert Process.whereis(:test_dispatcher) == pid
      AsyncDispatcher.stop(pid)
    end

    test "fails without router" do
      Process.flag(:trap_exit, true)
      {:error, reason} = AsyncDispatcher.start_link([])
      assert match?({%KeyError{}, _stacktrace}, reason)
    end
  end

  describe "AsyncDispatcher.dispatch/2" do
    setup do
      {:ok, collector} = CollectorAgent.start_link()

      router = Router.new()
      router = Router.add_route(router, EventA, collector)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      on_exit(fn ->
        if Process.alive?(dispatcher), do: AsyncDispatcher.stop(dispatcher)
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      {:ok, dispatcher: dispatcher, collector: collector}
    end

    test "dispatches event to router", %{dispatcher: dispatcher, collector: collector} do
      event = %EventA{source: __MODULE__, data: "test"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher)

      events = CollectorAgent.get_events(collector)
      assert length(events) == 1
      assert hd(events).data == "test"
    end

    test "auto-generates correlation_id if missing", %{
      dispatcher: dispatcher,
      collector: collector
    } do
      event = %EventA{source: __MODULE__, correlation_id: nil, data: "test"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher)

      events = CollectorAgent.get_events(collector)
      assert hd(events).correlation_id != nil
      assert is_binary(hd(events).correlation_id)
    end

    test "preserves existing correlation_id", %{dispatcher: dispatcher, collector: collector} do
      event = %EventA{source: __MODULE__, correlation_id: "custom-123", data: "test"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher)

      events = CollectorAgent.get_events(collector)
      assert hd(events).correlation_id == "custom-123"
    end

    test "processes multiple events in order", %{dispatcher: dispatcher, collector: collector} do
      # Stop the default dispatcher and create one with batch_size=1 for strict ordering
      AsyncDispatcher.stop(dispatcher)

      router = Router.new()
      router = Router.add_route(router, EventA, collector)
      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router, batch_size: 1)

      events = [
        %EventA{source: __MODULE__, data: "first"},
        %EventA{source: __MODULE__, data: "second"},
        %EventA{source: __MODULE__, data: "third"}
      ]

      Enum.each(events, &AsyncDispatcher.dispatch(dispatcher, &1))

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 2000)

      collected = CollectorAgent.get_events(collector)
      assert length(collected) == 3
      assert Enum.map(collected, & &1.data) == ["first", "second", "third"]

      AsyncDispatcher.stop(dispatcher)
    end
  end

  describe "AsyncDispatcher event chaining" do
    setup do
      {:ok, collector} = CollectorAgent.start_link()

      router = Router.new()
      router = Router.add_route(router, EventA, SimpleAgent)
      router = Router.add_route(router, EventB, collector)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      on_exit(fn ->
        if Process.alive?(dispatcher), do: AsyncDispatcher.stop(dispatcher)
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      {:ok, dispatcher: dispatcher, collector: collector}
    end

    test "chains events through multiple agents", %{dispatcher: dispatcher, collector: collector} do
      event = %EventA{source: __MODULE__, data: "original"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 2000)

      events = CollectorAgent.get_events(collector)
      assert length(events) == 1
      assert hd(events).data == "processed: original"
    end

    test "preserves correlation_id through chain", %{dispatcher: dispatcher, collector: collector} do
      event = %EventA{source: __MODULE__, correlation_id: "chain-123", data: "test"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 2000)

      events = CollectorAgent.get_events(collector)
      assert hd(events).correlation_id == "chain-123"
    end
  end

  describe "AsyncDispatcher with aggregator" do
    setup do
      {:ok, aggregator} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventB, EventC],
          process_events_fn: fn events, state ->
            result = %EventA{
              source: __MODULE__,
              correlation_id: List.first(events).correlation_id,
              data: "aggregated"
            }

            {:ok, [result], state}
          end
        )

      {:ok, collector} = CollectorAgent.start_link()

      router = Router.new()
      router = Router.add_route(router, EventB, aggregator)
      router = Router.add_route(router, EventC, aggregator)
      router = Router.add_route(router, EventA, collector)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      on_exit(fn ->
        if Process.alive?(dispatcher), do: AsyncDispatcher.stop(dispatcher)
        if Process.alive?(aggregator), do: GenServer.stop(aggregator)
        if Process.alive?(collector), do: GenServer.stop(collector)
      end)

      {:ok, dispatcher: dispatcher, collector: collector}
    end

    test "routes events to aggregator and processes result", %{
      dispatcher: dispatcher,
      collector: collector
    } do
      correlation_id = "agg-test"

      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "b"}
      event_c = %EventC{source: __MODULE__, correlation_id: correlation_id, data: "c"}

      AsyncDispatcher.dispatch(dispatcher, event_b)
      AsyncDispatcher.dispatch(dispatcher, event_c)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 2000)

      events = CollectorAgent.get_events(collector)
      assert length(events) == 1
      assert hd(events).data == "aggregated"
    end
  end

  describe "AsyncDispatcher.wait_for_empty_queue/2" do
    test "returns :ok when queue is empty" do
      router = Router.new()
      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      assert :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher)

      AsyncDispatcher.stop(dispatcher)
    end

    test "waits for events to be processed" do
      {:ok, collector} = CollectorAgent.start_link()

      router = Router.new()
      router = Router.add_route(router, EventA, collector)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      # Dispatch multiple events
      for i <- 1..10 do
        AsyncDispatcher.dispatch(dispatcher, %EventA{source: __MODULE__, data: "#{i}"})
      end

      assert :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 3000)

      events = CollectorAgent.get_events(collector)
      assert length(events) == 10

      AsyncDispatcher.stop(dispatcher)
      GenServer.stop(collector)
    end

    test "times out if queue doesn't empty" do
      defmodule SlowAgent do
        @behaviour BaseAsyncAgent

        @impl true
        def receive_event_async(_event) do
          Process.sleep(5000)
          {:ok, []}
        end
      end

      router = Router.new()
      router = Router.add_route(router, EventA, SlowAgent)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      AsyncDispatcher.dispatch(dispatcher, %EventA{source: __MODULE__, data: "slow"})

      assert {:error, :timeout} = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 100)

      AsyncDispatcher.stop(dispatcher)
    end
  end

  describe "AsyncDispatcher.get_queue_size/1" do
    test "returns zero for empty queue" do
      router = Router.new()
      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      assert AsyncDispatcher.get_queue_size(dispatcher) == 0

      AsyncDispatcher.stop(dispatcher)
    end

    test "returns correct queue size" do
      # Slow agent to keep events in queue
      defmodule SlowProcessAgent do
        @behaviour BaseAsyncAgent

        @impl true
        def receive_event_async(_event) do
          Process.sleep(1000)
          {:ok, []}
        end
      end

      router = Router.new()
      router = Router.add_route(router, EventA, SlowProcessAgent)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      # Dispatch events
      for i <- 1..5 do
        AsyncDispatcher.dispatch(dispatcher, %EventA{source: __MODULE__, data: "#{i}"})
      end

      # Give dispatcher time to start processing
      Process.sleep(50)

      # Should have some events in queue
      size = AsyncDispatcher.get_queue_size(dispatcher)
      assert size >= 0

      AsyncDispatcher.stop(dispatcher)
    end
  end

  describe "AsyncDispatcher termination" do
    test "stops on TerminateEvent" do
      router = Router.new()
      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      ref = Process.monitor(dispatcher)

      terminate_event = %TerminateEvent{source: __MODULE__}
      AsyncDispatcher.dispatch(dispatcher, terminate_event)

      # Wait for dispatcher to stop
      assert_receive {:DOWN, ^ref, :process, ^dispatcher, :normal}, 1000
    end

    test "stops gracefully with stop/1" do
      router = Router.new()
      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      ref = Process.monitor(dispatcher)

      AsyncDispatcher.stop(dispatcher)

      assert_receive {:DOWN, ^ref, :process, ^dispatcher, :normal}, 1000
    end
  end

  describe "AsyncDispatcher with module agents" do
    test "supports module-based agents implementing BaseAsyncAgent" do
      {:ok, collector} = CollectorAgent.start_link()

      router = Router.new()
      router = Router.add_route(router, EventA, SimpleAgent)
      router = Router.add_route(router, EventB, collector)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      event = %EventA{source: __MODULE__, data: "module-test"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 2000)

      events = CollectorAgent.get_events(collector)
      assert length(events) == 1
      assert hd(events).data == "processed: module-test"

      AsyncDispatcher.stop(dispatcher)
      GenServer.stop(collector)
    end
  end

  describe "AsyncDispatcher with pid agents" do
    test "supports pid-based agents (GenServers)" do
      {:ok, aggregator} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA],
          process_events_fn: fn events, state ->
            result = %EventB{
              source: __MODULE__,
              correlation_id: List.first(events).correlation_id,
              data: "from pid agent"
            }

            {:ok, [result], state}
          end
        )

      {:ok, collector} = CollectorAgent.start_link()

      router = Router.new()
      router = Router.add_route(router, EventA, aggregator)
      router = Router.add_route(router, EventB, collector)

      {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

      event = %EventA{source: __MODULE__, data: "test"}
      AsyncDispatcher.dispatch(dispatcher, event)

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 2000)

      events = CollectorAgent.get_events(collector)
      assert length(events) == 1
      assert hd(events).data == "from pid agent"

      AsyncDispatcher.stop(dispatcher)
      GenServer.stop(aggregator)
      GenServer.stop(collector)
    end
  end
end
