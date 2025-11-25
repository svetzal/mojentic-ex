defmodule Mojentic.Examples.React.ModelsTest do
  use ExUnit.Case, async: true

  alias Mojentic.Examples.React.Models.{
    NextAction,
    ThoughtActionObservation,
    Plan,
    CurrentContext
  }

  describe "NextAction" do
    test "parses valid action strings" do
      assert {:ok, :plan} = NextAction.parse("PLAN")
      assert {:ok, :act} = NextAction.parse("ACT")
      assert {:ok, :finish} = NextAction.parse("FINISH")
    end

    test "returns error for invalid action strings" do
      assert {:error, :invalid_action} = NextAction.parse("INVALID")
      assert {:error, :invalid_action} = NextAction.parse("plan")
      assert {:error, :invalid_action} = NextAction.parse("")
    end

    test "converts action atoms to strings" do
      assert "PLAN" = NextAction.to_string(:plan)
      assert "ACT" = NextAction.to_string(:act)
      assert "FINISH" = NextAction.to_string(:finish)
    end
  end

  describe "ThoughtActionObservation" do
    test "creates a new observation with all fields" do
      tao =
        ThoughtActionObservation.new(
          "I need to check the date",
          "Called resolve_date",
          "Date is 2025-11-28"
        )

      assert tao.thought == "I need to check the date"
      assert tao.action == "Called resolve_date"
      assert tao.observation == "Date is 2025-11-28"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(ThoughtActionObservation, %{})
      end
    end
  end

  describe "Plan" do
    test "creates an empty plan by default" do
      plan = Plan.new()
      assert plan.steps == []
    end

    test "creates a plan with steps" do
      steps = ["Identify the date", "Use resolve_date tool", "Format answer"]
      plan = Plan.new(steps)
      assert plan.steps == steps
    end
  end

  describe "CurrentContext" do
    test "creates a new context with required user_query" do
      context = CurrentContext.new("What is the date?")
      assert context.user_query == "What is the date?"
      assert %Plan{steps: []} = context.plan
      assert context.history == []
      assert context.iteration == 0
    end

    test "creates a context with custom options" do
      plan = Plan.new(["step1", "step2"])
      history = [ThoughtActionObservation.new("thought", "action", "observation")]

      context =
        CurrentContext.new("What is the date?",
          plan: plan,
          history: history,
          iteration: 3
        )

      assert context.user_query == "What is the date?"
      assert context.plan == plan
      assert context.history == history
      assert context.iteration == 3
    end

    test "enforces required user_query key" do
      assert_raise ArgumentError, fn ->
        struct!(CurrentContext, %{})
      end
    end
  end
end
