defmodule Mojentic.Examples.React.EventsTest do
  use ExUnit.Case, async: true

  alias Mojentic.Examples.React.Events.{
    InvokeThinking,
    InvokeDecisioning,
    InvokeToolCall,
    FinishAndSummarize,
    FailureOccurred
  }

  alias Mojentic.Examples.React.Models.CurrentContext
  alias Mojentic.LLM.Tools.DateResolver

  describe "InvokeThinking" do
    test "creates event with required fields" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeThinking{
        source: __MODULE__,
        context: context
      }

      assert event.source == __MODULE__
      assert event.context == context
      assert is_nil(event.correlation_id)
    end

    test "creates event with correlation_id" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeThinking{
        source: __MODULE__,
        context: context,
        correlation_id: "test-123"
      }

      assert event.correlation_id == "test-123"
    end
  end

  describe "InvokeDecisioning" do
    test "creates event with required fields" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeDecisioning{
        source: __MODULE__,
        context: context
      }

      assert event.source == __MODULE__
      assert event.context == context
    end
  end

  describe "InvokeToolCall" do
    test "creates event with all required fields" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeToolCall{
        source: __MODULE__,
        context: context,
        thought: "I need to resolve a date",
        action: :act,
        tool: DateResolver
      }

      assert event.source == __MODULE__
      assert event.context == context
      assert event.thought == "I need to resolve a date"
      assert event.action == :act
      assert event.tool == DateResolver
      assert event.tool_arguments == %{}
    end

    test "creates event with tool arguments" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeToolCall{
        source: __MODULE__,
        context: context,
        thought: "I need to resolve a date",
        action: :act,
        tool: DateResolver,
        tool_arguments: %{"relative_date_found" => "tomorrow"}
      }

      assert event.tool_arguments == %{"relative_date_found" => "tomorrow"}
    end
  end

  describe "FinishAndSummarize" do
    test "creates event with required fields" do
      context = CurrentContext.new("What is the date?")

      event = %FinishAndSummarize{
        source: __MODULE__,
        context: context,
        thought: "I have enough information to answer"
      }

      assert event.source == __MODULE__
      assert event.context == context
      assert event.thought == "I have enough information to answer"
    end
  end

  describe "FailureOccurred" do
    test "creates event with error information" do
      context = CurrentContext.new("What is the date?")

      event = %FailureOccurred{
        source: __MODULE__,
        context: context,
        reason: "Tool execution failed"
      }

      assert event.source == __MODULE__
      assert event.context == context
      assert event.reason == "Tool execution failed"
    end
  end
end
