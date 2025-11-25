#!/usr/bin/env elixir

# Solver Chat Session Example
#
# This example demonstrates how to wrap an IterativeProblemSolver as a tool
# within a ChatSession. This allows the LLM to delegate complex multi-step
# problems to the solver agent when needed.
#
# Usage:
#   mix run examples/solver_chat_session.exs
#
# Try queries like:
#   - "What day is next Friday?"
#   - "What was the date 3 weeks ago?"
#   - Regular chat queries that don't need the solver

alias Mojentic.Agents.IterativeProblemSolver
alias Mojentic.LLM.Broker
alias Mojentic.LLM.ChatSession
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.DateResolver

defmodule IterativeProblemSolverTool do
  @moduledoc """
  A tool that wraps IterativeProblemSolver to make it available as a tool
  within a ChatSession.

  This allows an LLM to delegate complex multi-step problems to a problem
  solver agent that can use its own set of tools iteratively.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  defstruct [:broker, :tools]

  @doc """
  Creates a new IterativeProblemSolverTool.

  ## Parameters

  - `broker` - The LLM broker to use for problem solving
  - `tools` - List of tool modules available to the solver

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)
      tool = IterativeProblemSolverTool.new(broker, [DateResolver])

  """
  def new(broker, tools) do
    %__MODULE__{
      broker: broker,
      tools: tools
    }
  end

  @impl true
  def run(%__MODULE__{broker: broker, tools: tools}, arguments) do
    problem_to_solve = Map.get(arguments, "problem_to_solve")

    if is_nil(problem_to_solve) or problem_to_solve == "" do
      {:error, "problem_to_solve is required"}
    else
      solver =
        IterativeProblemSolver.new(broker,
          tools: tools,
          max_iterations: 5
        )

      IterativeProblemSolver.solve(solver, problem_to_solve)
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "iterative_problem_solver",
        description:
          "Iteratively solve a complex multi-step problem using available tools. Use this when a query requires multiple steps or tool calls to answer.",
        parameters: %{
          type: "object",
          properties: %{
            problem_to_solve: %{
              type: "string",
              description: "The problem or request to be solved."
            }
          },
          required: ["problem_to_solve"],
          additionalProperties: false
        }
      }
    }
  end
end

defmodule SolverChatLoop do
  @moduledoc """
  Interactive chat loop for the solver chat session example.
  """

  def run(session) do
    query = IO.gets("Query: ") |> String.trim()

    if query == "" do
      IO.puts("\nGoodbye!")
    else
      case ChatSession.send(session, query) do
        {:ok, response, updated_session} ->
          IO.puts(response)
          IO.puts("")
          run(updated_session)

        {:error, reason} ->
          IO.puts("Error: #{inspect(reason)}")
          IO.puts("")
          run(session)
      end
    end
  end
end

# Main execution
IO.puts("=" |> String.duplicate(80))
IO.puts("SOLVER CHAT SESSION EXAMPLE")
IO.puts("=" |> String.duplicate(80))
IO.puts("")
IO.puts("This example wraps IterativeProblemSolver as a tool in a ChatSession.")
IO.puts("The LLM can delegate complex problems to the solver when needed.")
IO.puts("")
IO.puts("Available capabilities:")
IO.puts("  - Regular chat interactions")
IO.puts("  - Complex problem solving via iterative_problem_solver tool")
IO.puts("  - Date resolution through the solver's DateResolver tool")
IO.puts("")
IO.puts("Try queries like:")
IO.puts("  - 'What day is next Friday?'")
IO.puts("  - 'What was the date 3 weeks ago?'")
IO.puts("  - Regular conversational queries")
IO.puts("")
IO.puts("Type your query and press Enter. Empty line to exit.")
IO.puts("=" |> String.duplicate(80))
IO.puts("")

# Initialize the broker
# Try qwq first, fall back to qwen3:32b if qwq is not available
broker = Broker.new("qwq", Ollama)

# Create the solver tool with DateResolver as its inner tool
solver_tool = IterativeProblemSolverTool.new(broker, [DateResolver])

# Create the chat session with the solver tool
session = ChatSession.new(broker, tools: [solver_tool])

# Start the interactive loop
SolverChatLoop.run(session)
