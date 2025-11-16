defmodule Mojentic.Tracer.TracerEventsTest do
  use ExUnit.Case, async: true

  alias Mojentic.Tracer.TracerEvents.{
    TracerEvent,
    LLMCallTracerEvent,
    LLMResponseTracerEvent,
    ToolCallTracerEvent,
    AgentInteractionTracerEvent
  }

  describe "TracerEvent" do
    test "printable_summary formats timestamp and correlation_id" do
      event = %TracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "550e8400-e29b-41d4-a716-446655440000",
        source: MyModule
      }

      summary = TracerEvent.printable_summary(event)

      assert summary =~ ~r/\[\d{2}:\d{2}:\d{2}\.\d{3}\]/
      assert summary =~ "TracerEvent"
      assert summary =~ "550e8400-e29b-41d4-a716-446655440000"
    end
  end

  describe "LLMCallTracerEvent" do
    test "printable_summary includes model and message count" do
      event = %LLMCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        messages: [
          %{role: "user", content: "Hello"},
          %{role: "assistant", content: "Hi"}
        ],
        temperature: 1.0,
        tools: nil
      }

      summary = LLMCallTracerEvent.printable_summary(event)

      assert summary =~ "Model: gpt-4"
      assert summary =~ "2 messages"
    end

    test "printable_summary shows singular 'message' for single message" do
      event = %LLMCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        messages: [%{role: "user", content: "Hello"}],
        temperature: 1.0,
        tools: nil
      }

      summary = LLMCallTracerEvent.printable_summary(event)

      assert summary =~ "1 message"
      refute summary =~ "1 messages"
    end

    test "printable_summary includes temperature when not 1.0" do
      event = %LLMCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        messages: [],
        temperature: 0.7,
        tools: nil
      }

      summary = LLMCallTracerEvent.printable_summary(event)

      assert summary =~ "Temperature: 0.7"
    end

    test "printable_summary omits temperature when 1.0" do
      event = %LLMCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        messages: [],
        temperature: 1.0,
        tools: nil
      }

      summary = LLMCallTracerEvent.printable_summary(event)

      refute summary =~ "Temperature"
    end

    test "printable_summary includes tool names when present" do
      event = %LLMCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        messages: [],
        temperature: 1.0,
        tools: [
          %{"name" => "tool1"},
          %{"name" => "tool2"}
        ]
      }

      summary = LLMCallTracerEvent.printable_summary(event)

      assert summary =~ "Available Tools: tool1, tool2"
    end
  end

  describe "LLMResponseTracerEvent" do
    test "printable_summary includes model and content preview" do
      event = %LLMResponseTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        content: "This is a short response",
        tool_calls: nil,
        call_duration_ms: nil
      }

      summary = LLMResponseTracerEvent.printable_summary(event)

      assert summary =~ "Model: gpt-4"
      assert summary =~ "Content: This is a short response"
    end

    test "printable_summary truncates long content" do
      long_content = String.duplicate("a", 150)

      event = %LLMResponseTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        content: long_content,
        tool_calls: nil,
        call_duration_ms: nil
      }

      summary = LLMResponseTracerEvent.printable_summary(event)

      assert summary =~ "Content: #{String.slice(long_content, 0..99)}..."
    end

    test "printable_summary includes tool call count" do
      event = %LLMResponseTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        content: "",
        tool_calls: [%{}, %{}, %{}],
        call_duration_ms: nil
      }

      summary = LLMResponseTracerEvent.printable_summary(event)

      assert summary =~ "Tool Calls: 3 calls"
    end

    test "printable_summary includes duration when present" do
      event = %LLMResponseTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        model: "gpt-4",
        content: "",
        tool_calls: nil,
        call_duration_ms: 123.456
      }

      summary = LLMResponseTracerEvent.printable_summary(event)

      assert summary =~ "Duration: 123.46ms"
    end
  end

  describe "ToolCallTracerEvent" do
    test "printable_summary includes tool name and arguments" do
      event = %ToolCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        tool_name: "date_resolver",
        arguments: %{"days_offset" => 3},
        result: "2024-11-18",
        caller: nil,
        call_duration_ms: nil
      }

      summary = ToolCallTracerEvent.printable_summary(event)

      assert summary =~ "Tool: date_resolver"
      assert summary =~ ~s(Arguments: %{"days_offset" => 3})
    end

    test "printable_summary includes result" do
      event = %ToolCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        tool_name: "test_tool",
        arguments: %{},
        result: "success",
        caller: nil,
        call_duration_ms: nil
      }

      summary = ToolCallTracerEvent.printable_summary(event)

      assert summary =~ "Result: \"success\""
    end

    test "printable_summary truncates long results" do
      long_result = String.duplicate("x", 150)

      event = %ToolCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        tool_name: "test_tool",
        arguments: %{},
        result: long_result,
        caller: nil,
        call_duration_ms: nil
      }

      summary = ToolCallTracerEvent.printable_summary(event)

      assert summary =~ "Result: \"#{String.slice(long_result, 0..99)}..."
    end

    test "printable_summary includes caller when present" do
      event = %ToolCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        tool_name: "test_tool",
        arguments: %{},
        result: "ok",
        caller: "ChatSession",
        call_duration_ms: nil
      }

      summary = ToolCallTracerEvent.printable_summary(event)

      assert summary =~ "Caller: ChatSession"
    end

    test "printable_summary includes duration when present" do
      event = %ToolCallTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        tool_name: "test_tool",
        arguments: %{},
        result: "ok",
        caller: nil,
        call_duration_ms: 5.678
      }

      summary = ToolCallTracerEvent.printable_summary(event)

      assert summary =~ "Duration: 5.68ms"
    end
  end

  describe "AgentInteractionTracerEvent" do
    test "printable_summary includes from/to agents and event type" do
      event = %AgentInteractionTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        from_agent: "AgentA",
        to_agent: "AgentB",
        event_type: "request",
        event_id: nil
      }

      summary = AgentInteractionTracerEvent.printable_summary(event)

      assert summary =~ "From: AgentA → To: AgentB"
      assert summary =~ "Event Type: request"
    end

    test "printable_summary includes event_id when present" do
      event = %AgentInteractionTracerEvent{
        timestamp: 1_700_000_000.123,
        correlation_id: "abc-123",
        source: MyModule,
        from_agent: "AgentA",
        to_agent: "AgentB",
        event_type: "response",
        event_id: "event-456"
      }

      summary = AgentInteractionTracerEvent.printable_summary(event)

      assert summary =~ "Event ID: event-456"
    end
  end
end
