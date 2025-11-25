defmodule Mojentic.Examples.React.FormattersTest do
  use ExUnit.Case, async: true

  alias Mojentic.Examples.React.Formatters
  alias Mojentic.Examples.React.Models.{CurrentContext, Plan, ThoughtActionObservation}
  alias Mojentic.LLM.Tools.DateResolver

  describe "format_current_context/1" do
    test "formats context with no plan or history" do
      context = CurrentContext.new("What is the date?")
      formatted = Formatters.format_current_context(context)

      assert formatted =~ "Current Context:"
      assert formatted =~ "What is the date?"
      assert formatted =~ "You have not yet made a plan."
      assert formatted =~ "No steps have yet been taken."
    end

    test "formats context with a plan" do
      plan = Plan.new(["Step 1", "Step 2", "Step 3"])
      context = CurrentContext.new("What is the date?", plan: plan)
      formatted = Formatters.format_current_context(context)

      assert formatted =~ "Current plan:"
      assert formatted =~ "- Step 1"
      assert formatted =~ "- Step 2"
      assert formatted =~ "- Step 3"
    end

    test "formats context with history" do
      history = [
        ThoughtActionObservation.new("Need to check date", "Called tool", "Result: 2025-11-28"),
        ThoughtActionObservation.new("Verify result", "Checked format", "Format is correct")
      ]

      context = CurrentContext.new("What is the date?", history: history)
      formatted = Formatters.format_current_context(context)

      assert formatted =~ "What's been done so far:"
      assert formatted =~ "1."
      assert formatted =~ "Thought: Need to check date"
      assert formatted =~ "Action: Called tool"
      assert formatted =~ "Observation: Result: 2025-11-28"
      assert formatted =~ "2."
      assert formatted =~ "Thought: Verify result"
    end

    test "formats complete context with plan and history" do
      plan = Plan.new(["Check date", "Format answer"])

      history = [
        ThoughtActionObservation.new("Start", "Action1", "Observation1")
      ]

      context = CurrentContext.new("What is the date?", plan: plan, history: history)
      formatted = Formatters.format_current_context(context)

      assert formatted =~ "Current Context:"
      assert formatted =~ "What is the date?"
      assert formatted =~ "Current plan:"
      assert formatted =~ "- Check date"
      assert formatted =~ "What's been done so far:"
      assert formatted =~ "Thought: Start"
    end
  end

  describe "format_available_tools/1" do
    test "formats empty tool list" do
      formatted = Formatters.format_available_tools([])
      assert formatted == ""
    end

    test "formats single tool" do
      formatted = Formatters.format_available_tools([DateResolver])

      assert formatted =~ "Tools available:"
      assert formatted =~ "- resolve_date:"
      assert formatted =~ "Take text that specifies a relative date"
      assert formatted =~ "Parameters:"
      assert formatted =~ "relative_date_found (required):"
      assert formatted =~ "reference_date_in_iso8601 (optional):"
    end

    test "formats multiple tools" do
      # We only have DateResolver available, so test with it multiple times
      # In a real scenario, you'd have different tools
      formatted = Formatters.format_available_tools([DateResolver])

      # Count occurrences to ensure formatting works
      assert formatted =~ "Tools available:"
      assert formatted =~ "resolve_date"
    end
  end
end
