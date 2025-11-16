defmodule Mojentic.Tracer.TracerSystemTest do
  use ExUnit.Case, async: true

  alias Mojentic.Tracer.TracerSystem

  alias Mojentic.Tracer.TracerEvents.{
    TracerEvent,
    LLMCallTracerEvent,
    LLMResponseTracerEvent,
    ToolCallTracerEvent,
    AgentInteractionTracerEvent
  }

  setup do
    {:ok, tracer} = TracerSystem.start_link()
    {:ok, tracer: tracer}
  end

  describe "start_link/1" do
    test "starts with enabled tracing by default" do
      {:ok, tracer} = TracerSystem.start_link()
      assert TracerSystem.enabled?(tracer)
    end

    test "can start with tracing disabled" do
      {:ok, tracer} = TracerSystem.start_link(enabled: false)
      refute TracerSystem.enabled?(tracer)
    end

    test "can be started with a name" do
      {:ok, _tracer} = TracerSystem.start_link(name: :test_tracer)
      assert TracerSystem.enabled?(:test_tracer)
    end
  end

  describe "record_event/2" do
    test "records a generic tracer event", %{tracer: tracer} do
      event = %TracerEvent{
        timestamp: 1.0,
        correlation_id: "test",
        source: TestModule
      }

      :ok = TracerSystem.record_event(tracer, event)

      events = TracerSystem.get_events(tracer)
      assert length(events) == 1
      assert hd(events) == event
    end

    test "does not record when disabled", %{tracer: tracer} do
      TracerSystem.disable(tracer)

      event = %TracerEvent{
        timestamp: 1.0,
        correlation_id: "test",
        source: TestModule
      }

      :ok = TracerSystem.record_event(tracer, event)

      events = TracerSystem.get_events(tracer)
      assert events == []
    end
  end

  describe "record_llm_call/2" do
    test "records an LLM call event", %{tracer: tracer} do
      :ok =
        TracerSystem.record_llm_call(tracer,
          model: "gpt-4",
          messages: [%{role: "user", content: "Hello"}],
          temperature: 0.7,
          tools: nil,
          correlation_id: "corr-123"
        )

      events = TracerSystem.get_events(tracer, event_type: LLMCallTracerEvent)
      assert length(events) == 1

      event = hd(events)
      assert event.model == "gpt-4"
      assert event.temperature == 0.7
      assert event.correlation_id == "corr-123"
      assert length(event.messages) == 1
    end

    test "uses default temperature when not provided", %{tracer: tracer} do
      :ok =
        TracerSystem.record_llm_call(tracer,
          model: "gpt-4",
          messages: [],
          correlation_id: "corr-123"
        )

      events = TracerSystem.get_events(tracer, event_type: LLMCallTracerEvent)
      event = hd(events)
      assert event.temperature == 1.0
    end

    test "requires correlation_id", %{tracer: tracer} do
      result =
        TracerSystem.record_llm_call(tracer,
          model: "gpt-4",
          messages: []
        )

      assert {:error, %KeyError{}} = result
    end

    test "does not record when disabled", %{tracer: tracer} do
      TracerSystem.disable(tracer)

      :ok =
        TracerSystem.record_llm_call(tracer,
          model: "gpt-4",
          messages: [],
          correlation_id: "corr-123"
        )

      events = TracerSystem.get_events(tracer)
      assert events == []
    end
  end

  describe "record_llm_response/2" do
    test "records an LLM response event", %{tracer: tracer} do
      :ok =
        TracerSystem.record_llm_response(tracer,
          model: "gpt-4",
          content: "Hello! How can I help?",
          tool_calls: nil,
          call_duration_ms: 123.45,
          correlation_id: "corr-123"
        )

      events = TracerSystem.get_events(tracer, event_type: LLMResponseTracerEvent)
      assert length(events) == 1

      event = hd(events)
      assert event.model == "gpt-4"
      assert event.content == "Hello! How can I help?"
      assert event.call_duration_ms == 123.45
      assert event.correlation_id == "corr-123"
    end

    test "requires correlation_id", %{tracer: tracer} do
      result =
        TracerSystem.record_llm_response(tracer,
          model: "gpt-4",
          content: "Hello"
        )

      assert {:error, %KeyError{}} = result
    end
  end

  describe "record_tool_call/2" do
    test "records a tool call event", %{tracer: tracer} do
      :ok =
        TracerSystem.record_tool_call(tracer,
          tool_name: "date_resolver",
          arguments: %{"days_offset" => 3},
          result: "2024-11-18",
          caller: "ChatSession",
          call_duration_ms: 5.67,
          correlation_id: "corr-123"
        )

      events = TracerSystem.get_events(tracer, event_type: ToolCallTracerEvent)
      assert length(events) == 1

      event = hd(events)
      assert event.tool_name == "date_resolver"
      assert event.arguments == %{"days_offset" => 3}
      assert event.result == "2024-11-18"
      assert event.caller == "ChatSession"
      assert event.call_duration_ms == 5.67
      assert event.correlation_id == "corr-123"
    end

    test "requires correlation_id", %{tracer: tracer} do
      result =
        TracerSystem.record_tool_call(tracer,
          tool_name: "test",
          arguments: %{},
          result: "ok"
        )

      assert {:error, %KeyError{}} = result
    end
  end

  describe "record_agent_interaction/2" do
    test "records an agent interaction event", %{tracer: tracer} do
      :ok =
        TracerSystem.record_agent_interaction(tracer,
          from_agent: "AgentA",
          to_agent: "AgentB",
          event_type: "request",
          event_id: "event-456",
          correlation_id: "corr-123"
        )

      events = TracerSystem.get_events(tracer, event_type: AgentInteractionTracerEvent)
      assert length(events) == 1

      event = hd(events)
      assert event.from_agent == "AgentA"
      assert event.to_agent == "AgentB"
      assert event.event_type == "request"
      assert event.event_id == "event-456"
      assert event.correlation_id == "corr-123"
    end

    test "requires correlation_id", %{tracer: tracer} do
      result =
        TracerSystem.record_agent_interaction(tracer,
          from_agent: "A",
          to_agent: "B",
          event_type: "request"
        )

      assert {:error, %KeyError{}} = result
    end
  end

  describe "get_events/2" do
    setup %{tracer: tracer} do
      # Record various events
      TracerSystem.record_llm_call(tracer,
        model: "model1",
        messages: [],
        correlation_id: "corr-1"
      )

      TracerSystem.record_llm_response(tracer,
        model: "model1",
        content: "response",
        correlation_id: "corr-1"
      )

      TracerSystem.record_tool_call(tracer,
        tool_name: "tool1",
        arguments: %{},
        result: "ok",
        correlation_id: "corr-2"
      )

      :ok
    end

    test "returns all events when no filter provided", %{tracer: tracer} do
      events = TracerSystem.get_events(tracer)
      assert length(events) == 3
    end

    test "filters by event type", %{tracer: tracer} do
      events = TracerSystem.get_events(tracer, event_type: LLMCallTracerEvent)
      assert length(events) == 1
      assert hd(events).__struct__ == LLMCallTracerEvent
    end

    test "filters by custom function", %{tracer: tracer} do
      filter_func = fn event -> event.correlation_id == "corr-1" end
      events = TracerSystem.get_events(tracer, filter_func: filter_func)

      assert length(events) == 2
      assert Enum.all?(events, fn e -> e.correlation_id == "corr-1" end)
    end
  end

  describe "get_last_n_tracer_events/3" do
    setup %{tracer: tracer} do
      for i <- 1..5 do
        TracerSystem.record_llm_call(tracer,
          model: "model#{i}",
          messages: [],
          correlation_id: "corr-#{i}"
        )
      end

      :ok
    end

    test "returns last N events", %{tracer: tracer} do
      last_3 = TracerSystem.get_last_n_tracer_events(tracer, 3)
      assert length(last_3) == 3

      # Verify they're the last 3 (models 3, 4, 5)
      models = Enum.map(last_3, & &1.model)
      assert models == ["model3", "model4", "model5"]
    end

    test "filters by event type", %{tracer: tracer} do
      # Add a tool call event
      TracerSystem.record_tool_call(tracer,
        tool_name: "tool",
        arguments: %{},
        result: "ok",
        correlation_id: "tool-corr"
      )

      # Get last 2 LLM call events (should skip the tool call)
      last_2 = TracerSystem.get_last_n_tracer_events(tracer, 2, event_type: LLMCallTracerEvent)
      assert length(last_2) == 2
      assert Enum.all?(last_2, fn e -> e.__struct__ == LLMCallTracerEvent end)
    end
  end

  describe "clear/1" do
    test "removes all events", %{tracer: tracer} do
      TracerSystem.record_llm_call(tracer,
        model: "test",
        messages: [],
        correlation_id: "test"
      )

      assert length(TracerSystem.get_events(tracer)) == 1

      :ok = TracerSystem.clear(tracer)

      assert TracerSystem.get_events(tracer) == []
    end
  end

  describe "enable/1 and disable/1" do
    test "enable/disable control event recording", %{tracer: tracer} do
      # Initially enabled
      assert TracerSystem.enabled?(tracer)

      TracerSystem.record_llm_call(tracer,
        model: "test",
        messages: [],
        correlation_id: "1"
      )

      assert length(TracerSystem.get_events(tracer)) == 1

      # Disable
      :ok = TracerSystem.disable(tracer)
      refute TracerSystem.enabled?(tracer)

      TracerSystem.record_llm_call(tracer,
        model: "test",
        messages: [],
        correlation_id: "2"
      )

      # Still only 1 event (second wasn't recorded)
      assert length(TracerSystem.get_events(tracer)) == 1

      # Re-enable
      :ok = TracerSystem.enable(tracer)
      assert TracerSystem.enabled?(tracer)

      TracerSystem.record_llm_call(tracer,
        model: "test",
        messages: [],
        correlation_id: "3"
      )

      # Now we have 2 events
      assert length(TracerSystem.get_events(tracer)) == 2
    end
  end

  describe "callback integration" do
    test "calls on_store_callback when events are recorded" do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event_stored, event})
      end

      {:ok, tracer} = TracerSystem.start_link(on_store_callback: callback)

      TracerSystem.record_llm_call(tracer,
        model: "test",
        messages: [],
        correlation_id: "test"
      )

      assert_receive {:event_stored, %LLMCallTracerEvent{}}
    end
  end
end
