defmodule Mojentic.Examples.React.ToolCallAgentTest do
  use ExUnit.Case, async: true

  alias Mojentic.Examples.React.Events.{InvokeToolCall, InvokeDecisioning, FailureOccurred}
  alias Mojentic.Examples.React.Models.{CurrentContext, ThoughtActionObservation}
  alias Mojentic.Examples.React.ToolCallAgent
  alias Mojentic.LLM.Tools.DateResolver

  describe "receive_event_async/2" do
    test "executes tool successfully and returns decisioning event" do
      context = CurrentContext.new("What is the date tomorrow?")

      event = %InvokeToolCall{
        source: __MODULE__,
        context: context,
        thought: "I need to resolve the date",
        action: :act,
        tool: DateResolver,
        tool_arguments: %{"relative_date_found" => "tomorrow"},
        correlation_id: "test-123"
      }

      assert {:ok, [next_event]} = ToolCallAgent.receive_event_async(nil, event)
      assert %InvokeDecisioning{} = next_event
      assert next_event.source == ToolCallAgent
      assert next_event.correlation_id == "test-123"

      # Check that history was updated
      assert length(next_event.context.history) == 1
      [history_entry] = next_event.context.history
      assert %ThoughtActionObservation{} = history_entry
      assert history_entry.thought == "I need to resolve the date"
      assert history_entry.action =~ "resolve_date"
      assert history_entry.observation =~ "date"
    end

    test "returns failure event on tool error" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeToolCall{
        source: __MODULE__,
        context: context,
        thought: "Test",
        action: :act,
        tool: DateResolver,
        tool_arguments: %{},
        # Missing required argument
        correlation_id: "test-123"
      }

      assert {:ok, [failure_event]} = ToolCallAgent.receive_event_async(nil, event)
      assert %FailureOccurred{} = failure_event
      assert failure_event.reason =~ "Tool execution"
    end

    test "ignores non-InvokeToolCall events" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeDecisioning{
        source: __MODULE__,
        context: context
      }

      assert {:ok, []} = ToolCallAgent.receive_event_async(nil, event)
    end
  end
end
