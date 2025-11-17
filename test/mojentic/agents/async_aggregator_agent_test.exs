defmodule Mojentic.Agents.AsyncAggregatorAgentTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.AsyncAggregatorAgent
  alias Mojentic.Event

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

  defmodule ResultEvent do
    use Event
    defstruct [:source, :correlation_id, :result]
  end

  def simple_process_events(events, state) do
    result = %ResultEvent{
      source: __MODULE__,
      correlation_id: List.first(events).correlation_id,
      result: "processed #{length(events)} events"
    }

    {:ok, [result], state}
  end

  def combining_process_events(events, state) do
    event_a = Enum.find(events, &match?(%EventA{}, &1))
    event_b = Enum.find(events, &match?(%EventB{}, &1))

    result = %ResultEvent{
      source: __MODULE__,
      correlation_id: event_a.correlation_id,
      result: "#{event_a.data} + #{event_b.data}"
    }

    {:ok, [result], state}
  end

  describe "AsyncAggregatorAgent.start_link/1" do
    test "starts with required options" do
      {:ok, pid} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA, EventB],
          process_events_fn: &simple_process_events/2
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts with name registration" do
      {:ok, pid} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA, EventB],
          process_events_fn: &simple_process_events/2,
          name: :test_aggregator
        )

      assert Process.whereis(:test_aggregator) == pid
      GenServer.stop(pid)
    end

    test "fails without event_types_needed" do
      Process.flag(:trap_exit, true)

      {:error, reason} =
        AsyncAggregatorAgent.start_link(process_events_fn: &simple_process_events/2)

      assert match?({%KeyError{}, _stacktrace}, reason)
    end

    test "fails without process_events_fn" do
      Process.flag(:trap_exit, true)
      {:error, reason} = AsyncAggregatorAgent.start_link(event_types_needed: [EventA, EventB])
      assert match?({%KeyError{}, _stacktrace}, reason)
    end
  end

  describe "AsyncAggregatorAgent.receive_event/2" do
    setup do
      {:ok, pid} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA, EventB],
          process_events_fn: &simple_process_events/2
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, pid: pid}
    end

    test "receives first event without processing", %{pid: pid} do
      event = %EventA{source: __MODULE__, correlation_id: "test-1", data: "first"}

      assert {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event)
    end

    test "processes when all event types received", %{pid: pid} do
      correlation_id = "test-1"
      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "a"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "b"}

      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_a)
      {:ok, [result]} = AsyncAggregatorAgent.receive_event(pid, event_b)

      assert %ResultEvent{} = result
      assert result.correlation_id == correlation_id
      assert result.result == "processed 2 events"
    end

    test "handles events in any order", %{pid: pid} do
      correlation_id = "test-2"
      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "a"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "b"}

      # Receive B before A
      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_b)
      {:ok, [result]} = AsyncAggregatorAgent.receive_event(pid, event_a)

      assert %ResultEvent{} = result
    end

    test "isolates events by correlation_id", %{pid: pid} do
      event_a1 = %EventA{source: __MODULE__, correlation_id: "corr-1", data: "a1"}
      event_b1 = %EventB{source: __MODULE__, correlation_id: "corr-1", data: "b1"}
      event_a2 = %EventA{source: __MODULE__, correlation_id: "corr-2", data: "a2"}

      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_a1)
      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_a2)
      {:ok, [result]} = AsyncAggregatorAgent.receive_event(pid, event_b1)

      assert result.correlation_id == "corr-1"
    end
  end

  describe "AsyncAggregatorAgent.wait_for_events/3" do
    setup do
      {:ok, pid} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA, EventB],
          process_events_fn: &combining_process_events/2
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, pid: pid}
    end

    test "waits for events to arrive", %{pid: pid} do
      correlation_id = "wait-1"

      # Start waiting in a separate process
      waiter_task =
        Task.async(fn ->
          AsyncAggregatorAgent.wait_for_events(pid, correlation_id, timeout: 5000)
        end)

      # Give the waiter time to register
      Process.sleep(50)

      # Send events
      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "A"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "B"}

      AsyncAggregatorAgent.receive_event(pid, event_a)
      AsyncAggregatorAgent.receive_event(pid, event_b)

      # Waiter should receive result
      assert {:ok, [result]} = Task.await(waiter_task)
      assert result.result == "A + B"
    end

    test "returns immediately if events already complete", %{pid: pid} do
      correlation_id = "wait-2"

      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "X"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "Y"}

      AsyncAggregatorAgent.receive_event(pid, event_a)
      AsyncAggregatorAgent.receive_event(pid, event_b)

      # Should return immediately
      assert {:ok, [result]} =
               AsyncAggregatorAgent.wait_for_events(pid, correlation_id, timeout: 5000)

      assert result.result == "X + Y"
    end

    test "times out if events don't arrive", %{pid: pid} do
      correlation_id = "wait-timeout"

      # Only send one event
      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "A"}
      AsyncAggregatorAgent.receive_event(pid, event_a)

      # Should timeout
      assert catch_exit(AsyncAggregatorAgent.wait_for_events(pid, correlation_id, timeout: 100))
    end

    test "multiple waiters for same correlation_id", %{pid: pid} do
      correlation_id = "multi-wait"

      # Start multiple waiters
      waiters =
        for i <- 1..3 do
          Task.async(fn ->
            result = AsyncAggregatorAgent.wait_for_events(pid, correlation_id, timeout: 5000)
            {i, result}
          end)
        end

      Process.sleep(50)

      # Send events
      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "M"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "N"}

      AsyncAggregatorAgent.receive_event(pid, event_a)
      AsyncAggregatorAgent.receive_event(pid, event_b)

      # All waiters should receive result
      results = Task.await_many(waiters)

      assert length(results) == 3

      Enum.each(results, fn {_i, {:ok, [result]}} ->
        assert result.result == "M + N"
      end)
    end
  end

  describe "AsyncAggregatorAgent with three event types" do
    setup do
      {:ok, pid} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA, EventB, EventC],
          process_events_fn: fn events, state ->
            result = %ResultEvent{
              source: __MODULE__,
              correlation_id: List.first(events).correlation_id,
              result: "Got all three!"
            }

            {:ok, [result], state}
          end
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, pid: pid}
    end

    test "waits for all three event types", %{pid: pid} do
      correlation_id = "three-events"

      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "a"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "b"}
      event_c = %EventC{source: __MODULE__, correlation_id: correlation_id, data: "c"}

      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_a)
      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_b)
      {:ok, [result]} = AsyncAggregatorAgent.receive_event(pid, event_c)

      assert result.result == "Got all three!"
    end
  end

  describe "AsyncAggregatorAgent error handling" do
    def error_process_events(_events, _state) do
      {:error, :processing_failed}
    end

    test "handles process_events_fn errors" do
      {:ok, pid} =
        AsyncAggregatorAgent.start_link(
          event_types_needed: [EventA, EventB],
          process_events_fn: &error_process_events/2
        )

      correlation_id = "error-test"
      event_a = %EventA{source: __MODULE__, correlation_id: correlation_id, data: "a"}
      event_b = %EventB{source: __MODULE__, correlation_id: correlation_id, data: "b"}

      {:ok, []} = AsyncAggregatorAgent.receive_event(pid, event_a)
      assert {:error, :processing_failed} = AsyncAggregatorAgent.receive_event(pid, event_b)

      GenServer.stop(pid)
    end
  end
end
