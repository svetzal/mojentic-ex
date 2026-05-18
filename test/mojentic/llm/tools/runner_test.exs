defmodule Mojentic.LLM.Tools.RunnerTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.ParallelToolRunner
  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.SerialToolRunner
  alias Mojentic.LLM.Tools.ToolCallExecution

  # ---------------------------------------------------------------------------
  # Helper tools for the runner tests.
  # ---------------------------------------------------------------------------

  defmodule EchoTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args), do: {:ok, %{echo: Map.get(args, "value", "")}}

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "echo",
          description: "Echo input",
          parameters: %{
            type: "object",
            properties: %{value: %{type: "string"}},
            required: []
          }
        }
      }
    end
  end

  defmodule RaisingTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, _args), do: raise("boom")

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "raises",
          description: "Always raises",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  defmodule SlowTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args) do
      Process.sleep(Map.get(args, "delay_ms", 50))
      {:ok, %{value: Map.get(args, "value", "x")}}
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "slow",
          description: "Sleeps then returns",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  # ---------------------------------------------------------------------------

  describe "SerialToolRunner" do
    test "preserves input order" do
      calls = [
        ToolCallExecution.new("1", "echo", %{"value" => "a"}),
        ToolCallExecution.new("2", "echo", %{"value" => "b"}),
        ToolCallExecution.new("3", "echo", %{"value" => "c"})
      ]

      outcomes = SerialToolRunner.run_batch(calls, [EchoTool])

      assert Enum.map(outcomes, & &1.id) == ["1", "2", "3"]
      assert Enum.map(outcomes, & &1.result.echo) == ["a", "b", "c"]
      assert Enum.all?(outcomes, & &1.ok?)
    end

    test "captures raises as ok?: false outcomes" do
      calls = [ToolCallExecution.new("1", "raises", %{})]
      outcomes = SerialToolRunner.run_batch(calls, [RaisingTool])

      [outcome] = outcomes
      refute outcome.ok?
      assert match?({:exception, _}, outcome.error)
    end

    test "marks unknown tools as :tool_not_found" do
      calls = [ToolCallExecution.new("1", "missing", %{})]
      outcomes = SerialToolRunner.run_batch(calls, [EchoTool])

      [outcome] = outcomes
      refute outcome.ok?
      assert outcome.error == {:tool_not_found, "missing"}
    end
  end

  describe "ParallelToolRunner" do
    test "dispatches calls in parallel" do
      delay = 100

      calls =
        for i <- 1..4,
            do: ToolCallExecution.new("#{i}", "slow", %{"value" => "#{i}", "delay_ms" => delay})

      runner = ParallelToolRunner.new(max_concurrency: 4)

      {time, outcomes} =
        :timer.tc(fn -> ParallelToolRunner.run_with(runner, calls, [SlowTool]) end)

      elapsed_ms = time / 1000
      assert length(outcomes) == 4
      assert Enum.all?(outcomes, & &1.ok?)
      assert elapsed_ms < delay * 3, "expected parallel dispatch, took #{elapsed_ms}ms"
    end

    test "preserves output order regardless of completion order" do
      calls = [
        ToolCallExecution.new("a", "slow", %{"value" => "a", "delay_ms" => 50}),
        ToolCallExecution.new("b", "slow", %{"value" => "b", "delay_ms" => 10}),
        ToolCallExecution.new("c", "slow", %{"value" => "c", "delay_ms" => 30})
      ]

      runner = ParallelToolRunner.new(max_concurrency: 4)
      outcomes = ParallelToolRunner.run_with(runner, calls, [SlowTool])

      assert Enum.map(outcomes, & &1.id) == ["a", "b", "c"]
      assert Enum.map(outcomes, & &1.result.value) == ["a", "b", "c"]
    end

    test "rejects non-positive concurrency" do
      assert_raise ArgumentError, fn -> ParallelToolRunner.new(max_concurrency: 0) end
    end

    test "respects cancellation in context before dispatching" do
      ref = :atomics.new(1, signed: false)
      :atomics.put(ref, 1, 1)
      ctx = RunContext.new(cancel_ref: ref)

      calls = [ToolCallExecution.new("1", "echo", %{"value" => "x"})]
      outcomes = ParallelToolRunner.run_batch(calls, [EchoTool], ctx)

      [outcome] = outcomes
      refute outcome.ok?
      assert outcome.error == :cancelled
    end
  end
end
