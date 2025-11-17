# Iterative Problem Solver Example
#
# This example demonstrates how to use the IterativeProblemSolver agent
# to solve problems using available tools. The agent will iteratively work
# through the problem until it succeeds, fails, or reaches max iterations.
#
# Usage:
#   mix run examples/iterative_solver.exs

alias Mojentic.Agents.IterativeProblemSolver
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.{DateResolver, AskUser}

# Initialize the LLM broker with Ollama
# You can change the model to any available Ollama model
# Examples: "qwen3:32b", "qwq", "llama3:70b", etc.
broker = Broker.new("qwen3:32b", Ollama)

# Define the user request
user_request = "What's the date next Friday?"

IO.puts("=" |> String.duplicate(80))
IO.puts("ITERATIVE PROBLEM SOLVER EXAMPLE")
IO.puts("=" |> String.duplicate(80))
IO.puts("")
IO.puts("User Request:")
IO.puts("  #{user_request}")
IO.puts("")
IO.puts("Available Tools:")
IO.puts("  - DateResolver: Resolves relative dates to absolute dates")
IO.puts("  - AskUser: Asks the user for help or information")
IO.puts("")
IO.puts("Max Iterations: 5")
IO.puts("")
IO.puts("=" |> String.duplicate(80))
IO.puts("")

# Create the problem solver with necessary tools
solver =
  IterativeProblemSolver.new(broker,
    tools: [DateResolver, AskUser],
    max_iterations: 5
  )

# Run the solver and get the result
IO.puts("Starting solver...")
IO.puts("")

case IterativeProblemSolver.solve(solver, user_request) do
  {:ok, result} ->
    IO.puts("")
    IO.puts("=" |> String.duplicate(80))
    IO.puts("FINAL RESULT")
    IO.puts("=" |> String.duplicate(80))
    IO.puts(result)
    IO.puts("=" |> String.duplicate(80))

  {:error, reason} ->
    IO.puts("")
    IO.puts("=" |> String.duplicate(80))
    IO.puts("ERROR")
    IO.puts("=" |> String.duplicate(80))
    IO.puts("Failed to solve problem: #{inspect(reason)}")
    IO.puts("=" |> String.duplicate(80))
end
