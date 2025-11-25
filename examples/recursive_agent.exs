#!/usr/bin/env elixir

# SimpleRecursiveAgent example
#
# For comprehensive documentation on the SimpleRecursiveAgent pattern, see:
# guides/simple_recursive_agent.md
#
# This example demonstrates the SimpleRecursiveAgent, which uses an event-driven
# async approach to solve problems recursively with LLM and tools.
#
# Usage:
#   mix run examples/recursive_agent.exs
#
# This will demonstrate:
# - Basic problem solving with recursive iterations
# - Event-driven architecture with async processing
# - Automatic tool integration
# - Handling DONE/FAIL completion signals

alias Mojentic.LLM.{Broker, Gateways.Ollama}
alias Mojentic.LLM.Tools.{DateResolver, CurrentDatetime}
alias Mojentic.Agents.SimpleRecursiveAgent
alias Mojentic.Agents.SimpleRecursiveAgent.{
  GoalSubmittedEvent,
  IterationCompletedEvent,
  GoalAchievedEvent,
  GoalFailedEvent
}

# Create broker
broker = Broker.new("qwen3:32b", Ollama)

# Create agent with tools
agent =
  SimpleRecursiveAgent.new(broker,
    tools: [DateResolver, CurrentDatetime],
    max_iterations: 5
  )

# Subscribe to events for observability
SimpleRecursiveAgent.EventEmitter.subscribe(
  agent.emitter,
  GoalSubmittedEvent,
  fn event ->
    IO.puts("\n🎯 Goal Submitted")
    IO.puts("   Problem: #{event.state.goal}")
    IO.puts("   Max iterations: #{event.state.max_iterations}")
  end
)

SimpleRecursiveAgent.EventEmitter.subscribe(
  agent.emitter,
  IterationCompletedEvent,
  fn event ->
    IO.puts("\n🔄 Iteration #{event.state.iteration} Completed")
    IO.puts("   Response: #{String.slice(event.response, 0, 100)}...")
  end
)

SimpleRecursiveAgent.EventEmitter.subscribe(
  agent.emitter,
  GoalAchievedEvent,
  fn event ->
    IO.puts("\n✅ Goal Achieved!")
    IO.puts("   Iterations: #{event.state.iteration}")
  end
)

SimpleRecursiveAgent.EventEmitter.subscribe(
  agent.emitter,
  GoalFailedEvent,
  fn event ->
    IO.puts("\n❌ Goal Failed")
    IO.puts("   Iterations: #{event.state.iteration}")
  end
)

# Example 1: Simple problem
IO.puts("=" |> String.duplicate(60))
IO.puts("Example 1: Simple Math Problem")
IO.puts("=" |> String.duplicate(60))

case SimpleRecursiveAgent.solve(agent, "What is 15 * 23?") do
  {:ok, result} ->
    IO.puts("\n📊 Final Result:")
    IO.puts(result)

  {:error, reason} ->
    IO.puts("\n❌ Error: #{inspect(reason)}")
end

# Wait a moment before next example
Process.sleep(1000)

# Example 2: Problem requiring tools
IO.puts("\n")
IO.puts("=" |> String.duplicate(60))
IO.puts("Example 2: Date Calculation with Tools")
IO.puts("=" |> String.duplicate(60))

case SimpleRecursiveAgent.solve(agent, "What day of the week will it be in 10 days?") do
  {:ok, result} ->
    IO.puts("\n📊 Final Result:")
    IO.puts(result)

  {:error, reason} ->
    IO.puts("\n❌ Error: #{inspect(reason)}")
end

# Wait a moment before next example
Process.sleep(1000)

# Example 3: Multi-step reasoning
IO.puts("\n")
IO.puts("=" |> String.duplicate(60))
IO.puts("Example 3: Multi-step Reasoning")
IO.puts("=" |> String.duplicate(60))

problem = """
If today is Monday and I need to finish a project that takes 3 days,
and I can only work on weekdays, when will I finish?
"""

case SimpleRecursiveAgent.solve(agent, problem) do
  {:ok, result} ->
    IO.puts("\n📊 Final Result:")
    IO.puts(result)

  {:error, reason} ->
    IO.puts("\n❌ Error: #{inspect(reason)}")
end

IO.puts("\n")
IO.puts("=" |> String.duplicate(60))
IO.puts("Examples Complete")
IO.puts("=" |> String.duplicate(60))
