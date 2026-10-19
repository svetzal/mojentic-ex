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

  defmodule ControlledTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args) do
      send(Map.fetch!(args, "owner"), {:tool_started, Map.fetch!(args, "value"), self()})

      receive do
        :release -> :ok
      end

      send(Map.fetch!(args, "owner"), {:tool_finished, Map.fetch!(args, "value")})
      {:ok, %{value: Map.get(args, "value", "x")}}
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "slow",
          description: "Waits for explicit release then returns",
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

    test "returns empty list for empty call list" do
      assert [] = SerialToolRunner.run_batch([], [EchoTool])
    end

    test "aborts remaining calls when context is cancelled" do
      ref = :atomics.new(1, signed: false)
      :atomics.put(ref, 1, 1)
      ctx = RunContext.new(cancel_ref: ref)

      calls = [
        ToolCallExecution.new("1", "echo", %{"value" => "a"}),
        ToolCallExecution.new("2", "echo", %{"value" => "b"})
      ]

      outcomes = SerialToolRunner.run_batch(calls, [EchoTool], ctx)

      assert Enum.all?(outcomes, fn o -> not o.ok? and o.error == :cancelled end)
    end
  end

  describe "ParallelToolRunner" do
    test "dispatches calls in parallel" do
      calls =
        for i <- 1..4,
            do: ToolCallExecution.new("#{i}", "slow", %{"value" => "#{i}", "owner" => self()})

      runner = ParallelToolRunner.new(max_concurrency: 2)
      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          ParallelToolRunner.run_with(runner, calls, [ControlledTool])
        end)

      assert_receive {:tool_started, first, first_worker}
      assert_receive {:tool_started, second, second_worker}
      assert Enum.sort([first, second]) == ["1", "2"]
      refute_received {:tool_started, _, _}
      send(first_worker, :release)
      assert_receive {:tool_finished, ^first}
      assert_receive {:tool_started, "3", third_worker}
      refute_received {:tool_started, "4", _}
      send(second_worker, :release)
      assert_receive {:tool_started, "4", fourth_worker}
      send(third_worker, :release)
      send(fourth_worker, :release)

      outcomes = Task.await(task)
      assert Enum.map(outcomes, & &1.id) == ["1", "2", "3", "4"]
      assert Enum.map(outcomes, & &1.result.value) == ["1", "2", "3", "4"]
      assert Enum.all?(outcomes, & &1.ok?)
    end

    test "preserves output order regardless of completion order" do
      calls =
        for id <- ["a", "b", "c"],
            do: ToolCallExecution.new(id, "slow", %{"value" => id, "owner" => self()})

      runner = ParallelToolRunner.new(max_concurrency: 3)
      supervisor = start_supervised!(Task.Supervisor)
      owner = self()

      context =
        RunContext.new(
          on_call_complete: fn outcome -> send(owner, {:outcome_completed, outcome.id}) end
        )

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          ParallelToolRunner.run_with(runner, calls, [ControlledTool], context)
        end)

      workers =
        for _ <- 1..3 do
          assert_receive {:tool_started, id, worker}
          {id, worker}
        end
        |> Map.new()

      for id <- ["c", "b", "a"] do
        send(Map.fetch!(workers, id), :release)
        assert_receive {:tool_finished, ^id}
        assert_receive {:outcome_completed, ^id}
      end

      outcomes = Task.await(task)
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
