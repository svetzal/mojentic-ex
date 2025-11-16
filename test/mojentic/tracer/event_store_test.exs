defmodule Mojentic.Tracer.EventStoreTest do
  use ExUnit.Case, async: true

  alias Mojentic.Tracer.EventStore
  alias Mojentic.Tracer.TracerEvents.{
    TracerEvent,
    LLMCallTracerEvent,
    LLMResponseTracerEvent
  }

  setup do
    {:ok, store} = EventStore.start_link()
    {:ok, store: store}
  end

  describe "start_link/1" do
    test "starts with empty event list" do
      {:ok, store} = EventStore.start_link()
      events = EventStore.get_events(store)
      assert events == []
    end

    test "accepts on_store_callback option" do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:callback_called, event})
      end

      {:ok, store} = EventStore.start_link(on_store_callback: callback)

      event = %TracerEvent{
        timestamp: 1.0,
        correlation_id: "test",
        source: TestModule
      }

      EventStore.store(store, event)

      assert_receive {:callback_called, ^event}
    end

    test "can be started with a name" do
      {:ok, _store} = EventStore.start_link(name: :test_store)
      events = EventStore.get_events(:test_store)
      assert events == []
    end
  end

  describe "store/2" do
    test "stores an event", %{store: store} do
      event = %TracerEvent{
        timestamp: 1.0,
        correlation_id: "test",
        source: TestModule
      }

      assert :ok = EventStore.store(store, event)

      events = EventStore.get_events(store)
      assert length(events) == 1
      assert hd(events) == event
    end

    test "stores multiple events in order", %{store: store} do
      event1 = %TracerEvent{timestamp: 1.0, correlation_id: "1", source: Mod1}
      event2 = %TracerEvent{timestamp: 2.0, correlation_id: "2", source: Mod2}
      event3 = %TracerEvent{timestamp: 3.0, correlation_id: "3", source: Mod3}

      EventStore.store(store, event1)
      EventStore.store(store, event2)
      EventStore.store(store, event3)

      events = EventStore.get_events(store)
      assert length(events) == 3
      assert events == [event1, event2, event3]
    end
  end

  describe "get_events/2" do
    setup %{store: store} do
      event1 = %LLMCallTracerEvent{
        timestamp: 1.0,
        correlation_id: "corr-1",
        source: Mod1,
        model: "model1",
        messages: [],
        temperature: 1.0,
        tools: nil
      }

      event2 = %LLMResponseTracerEvent{
        timestamp: 2.0,
        correlation_id: "corr-1",
        source: Mod2,
        model: "model1",
        content: "response",
        tool_calls: nil,
        call_duration_ms: nil
      }

      event3 = %LLMCallTracerEvent{
        timestamp: 3.0,
        correlation_id: "corr-2",
        source: Mod3,
        model: "model2",
        messages: [],
        temperature: 0.7,
        tools: nil
      }

      EventStore.store(store, event1)
      EventStore.store(store, event2)
      EventStore.store(store, event3)

      {:ok, event1: event1, event2: event2, event3: event3}
    end

    test "returns all events when no filter provided", %{store: store} do
      events = EventStore.get_events(store)
      assert length(events) == 3
    end

    test "filters by event type", %{store: store, event1: event1, event3: event3} do
      events = EventStore.get_events(store, event_type: LLMCallTracerEvent)
      assert length(events) == 2
      assert event1 in events
      assert event3 in events
    end

    test "filters by start_time", %{store: store, event2: event2, event3: event3} do
      events = EventStore.get_events(store, start_time: 2.0)
      assert length(events) == 2
      assert event2 in events
      assert event3 in events
    end

    test "filters by end_time", %{store: store, event1: event1, event2: event2} do
      events = EventStore.get_events(store, end_time: 2.0)
      assert length(events) == 2
      assert event1 in events
      assert event2 in events
    end

    test "filters by time range", %{store: store, event2: event2} do
      events = EventStore.get_events(store, start_time: 1.5, end_time: 2.5)
      assert length(events) == 1
      assert hd(events) == event2
    end

    test "filters by custom function", %{store: store, event1: event1, event2: event2} do
      filter_func = fn event -> event.correlation_id == "corr-1" end
      events = EventStore.get_events(store, filter_func: filter_func)

      assert length(events) == 2
      assert event1 in events
      assert event2 in events
    end

    test "combines multiple filters", %{store: store, event1: event1} do
      events =
        EventStore.get_events(store,
          event_type: LLMCallTracerEvent,
          start_time: 0.5,
          end_time: 1.5,
          filter_func: fn event -> event.correlation_id == "corr-1" end
        )

      assert length(events) == 1
      assert hd(events) == event1
    end
  end

  describe "get_last_n_events/3" do
    setup %{store: store} do
      events =
        for i <- 1..10 do
          %TracerEvent{
            timestamp: i * 1.0,
            correlation_id: "corr-#{i}",
            source: Module.concat([:"Mod#{i}"])
          }
        end

      Enum.each(events, &EventStore.store(store, &1))

      {:ok, all_events: events}
    end

    test "returns last N events", %{store: store, all_events: all_events} do
      last_3 = EventStore.get_last_n_events(store, 3)
      assert length(last_3) == 3
      assert last_3 == Enum.take(all_events, -3)
    end

    test "returns all events when N is larger than total", %{store: store, all_events: all_events} do
      all = EventStore.get_last_n_events(store, 20)
      assert length(all) == 10
      assert all == all_events
    end

    test "filters by event type", %{store: store} do
      llm_event = %LLMCallTracerEvent{
        timestamp: 11.0,
        correlation_id: "llm",
        source: LLMModule,
        model: "test",
        messages: [],
        temperature: 1.0,
        tools: nil
      }

      EventStore.store(store, llm_event)

      last = EventStore.get_last_n_events(store, 1, event_type: LLMCallTracerEvent)
      assert length(last) == 1
      assert hd(last) == llm_event
    end
  end

  describe "clear/1" do
    test "removes all events", %{store: store} do
      event = %TracerEvent{timestamp: 1.0, correlation_id: "test", source: Mod}
      EventStore.store(store, event)

      assert length(EventStore.get_events(store)) == 1

      :ok = EventStore.clear(store)

      assert EventStore.get_events(store) == []
    end
  end

  describe "callback error handling" do
    test "continues operation even if callback raises error" do
      test_pid = self()

      callback = fn _event ->
        send(test_pid, :callback_called)
        raise "Callback error!"
      end

      {:ok, store} = EventStore.start_link(on_store_callback: callback)

      event = %TracerEvent{timestamp: 1.0, correlation_id: "test", source: Mod}

      # Should not crash even though callback raises
      assert :ok = EventStore.store(store, event)

      assert_receive :callback_called

      # Event should still be stored
      events = EventStore.get_events(store)
      assert length(events) == 1
    end
  end
end
