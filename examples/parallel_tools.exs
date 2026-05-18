# Parallel Tool Execution Example
#
# Demonstrates the ParallelToolRunner dispatching multiple tool calls
# concurrently using Task.async_stream.  No external dependencies —
# runs against a stub "slow" tool so you can observe the timing
# difference between serial and parallel execution.
#
# Usage:
#   mix run examples/parallel_tools.exs

alias Mojentic.LLM.Tools.ParallelToolRunner
alias Mojentic.LLM.Tools.SerialToolRunner
alias Mojentic.LLM.Tools.ToolCallExecution

# ---------------------------------------------------------------------------
# A synthetic tool that sleeps for a given number of milliseconds, letting
# us measure whether execution is truly concurrent.
# ---------------------------------------------------------------------------

defmodule SlowTool do
  @behaviour Mojentic.LLM.Tools.Tool

  @impl true
  def run(_tool, args) do
    ms = Map.get(args, "delay_ms", 100)
    label = Map.get(args, "label", "?")
    Process.sleep(ms)
    {:ok, %{label: label, slept_ms: ms}}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "slow",
        description: "Sleep for delay_ms milliseconds",
        parameters: %{
          type: "object",
          properties: %{
            delay_ms: %{type: "integer", description: "ms to sleep"},
            label: %{type: "string", description: "call identifier"}
          },
          required: ["delay_ms", "label"]
        }
      }
    }
  end
end

calls = [
  ToolCallExecution.new("1", "slow", %{"delay_ms" => 200, "label" => "A"}),
  ToolCallExecution.new("2", "slow", %{"delay_ms" => 200, "label" => "B"}),
  ToolCallExecution.new("3", "slow", %{"delay_ms" => 200, "label" => "C"}),
  ToolCallExecution.new("4", "slow", %{"delay_ms" => 200, "label" => "D"})
]

IO.puts("Running 4 calls × 200 ms each...\n")

# Serial
{serial_us, serial_outcomes} =
  :timer.tc(fn -> SerialToolRunner.run_batch(calls, [SlowTool]) end)

IO.puts("Serial:   #{div(serial_us, 1000)} ms")
IO.puts("Results:  #{Enum.map(serial_outcomes, & &1.result.label) |> Enum.join(", ")}")

# Parallel (max_concurrency: 4)
runner = ParallelToolRunner.new(max_concurrency: 4)

{parallel_us, parallel_outcomes} =
  :timer.tc(fn -> ParallelToolRunner.run_with(runner, calls, [SlowTool]) end)

IO.puts("\nParallel: #{div(parallel_us, 1000)} ms  (max_concurrency: 4)")
IO.puts("Results:  #{Enum.map(parallel_outcomes, & &1.result.label) |> Enum.join(", ")}")

speedup = serial_us / parallel_us

IO.puts("""

Speedup: #{:erlang.float_to_binary(speedup, decimals: 1)}×
Order preserved: #{Enum.map(parallel_outcomes, & &1.id) == ["1", "2", "3", "4"]}
""")
