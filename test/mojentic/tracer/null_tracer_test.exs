defmodule Mojentic.Tracer.NullTracerTest do
  use ExUnit.Case, async: true

  alias Mojentic.Tracer.NullTracer
  alias Mojentic.Tracer.TracerEvents.{
    TracerEvent,
    LLMCallTracerEvent
  }

  describe "null tracer singleton" do
    test "record_event does nothing and returns :ok" do
      event = %TracerEvent{
        timestamp: 1.0,
        correlation_id: "test",
        source: TestModule
      }

      assert :ok = NullTracer.record_event(:null_tracer, event)
    end

    test "record_llm_call does nothing and returns :ok" do
      assert :ok =
               NullTracer.record_llm_call(:null_tracer,
                 model: "gpt-4",
                 messages: [],
                 correlation_id: "test"
               )
    end

    test "record_llm_response does nothing and returns :ok" do
      assert :ok =
               NullTracer.record_llm_response(:null_tracer,
                 model: "gpt-4",
                 content: "Hello",
                 correlation_id: "test"
               )
    end

    test "record_tool_call does nothing and returns :ok" do
      assert :ok =
               NullTracer.record_tool_call(:null_tracer,
                 tool_name: "tool",
                 arguments: %{},
                 result: "ok",
                 correlation_id: "test"
               )
    end

    test "record_agent_interaction does nothing and returns :ok" do
      assert :ok =
               NullTracer.record_agent_interaction(:null_tracer,
                 from_agent: "A",
                 to_agent: "B",
                 event_type: "request",
                 correlation_id: "test"
               )
    end

    test "get_events always returns empty list" do
      assert [] = NullTracer.get_events(:null_tracer)
      assert [] = NullTracer.get_events(:null_tracer, event_type: LLMCallTracerEvent)
      assert [] = NullTracer.get_events(:null_tracer, start_time: 0, end_time: 100)
    end

    test "get_last_n_tracer_events always returns empty list" do
      assert [] = NullTracer.get_last_n_tracer_events(:null_tracer, 10)
      assert [] = NullTracer.get_last_n_tracer_events(:null_tracer, 5, event_type: LLMCallTracerEvent)
    end

    test "clear does nothing and returns :ok" do
      assert :ok = NullTracer.clear(:null_tracer)
    end

    test "enable does nothing and returns :ok" do
      assert :ok = NullTracer.enable(:null_tracer)
    end

    test "disable does nothing and returns :ok" do
      assert :ok = NullTracer.disable(:null_tracer)
    end

    test "enabled? always returns false" do
      assert false == NullTracer.enabled?(:null_tracer)
    end
  end

  describe "null object pattern benefits" do
    test "can be used without conditional checks" do
      # This demonstrates that the null tracer can be used in the same way
      # as a real tracer, eliminating the need for `if tracer != nil` checks

      tracer = :null_tracer

      # All these operations work without errors
      NullTracer.record_llm_call(tracer,
        model: "test",
        messages: [],
        correlation_id: "test"
      )

      NullTracer.record_llm_response(tracer,
        model: "test",
        content: "test",
        correlation_id: "test"
      )

      events = NullTracer.get_events(tracer)
      assert events == []

      # Can safely query
      last_events = NullTracer.get_last_n_tracer_events(tracer, 10)
      assert last_events == []
    end
  end
end
