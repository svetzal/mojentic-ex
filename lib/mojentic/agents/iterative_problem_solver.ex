defmodule Mojentic.Agents.IterativeProblemSolver do
  @moduledoc """
  An agent that iteratively attempts to solve a problem using available tools.

  This solver uses a chat-based approach to break down and solve complex problems.
  It will continue attempting to solve the problem until it either succeeds,
  fails explicitly, or reaches the maximum number of iterations.

  The solver uses the ChatSession to maintain conversation state and automatically
  handles tool calls through the broker. It monitors the LLM's responses for
  completion indicators ("DONE" or "FAIL") to determine when to stop iterating.

  ## Usage

      alias Mojentic.LLM.Broker
      alias Mojentic.LLM.Gateways.Ollama
      alias Mojentic.LLM.Tools.{DateResolver, AskUser}
      alias Mojentic.Agents.IterativeProblemSolver

      broker = Broker.new("qwen3:32b", Ollama)

      solver = IterativeProblemSolver.new(
        broker,
        tools: [DateResolver, AskUser],
        max_iterations: 5
      )

      case IterativeProblemSolver.solve(solver, "What's the date next Friday?") do
        {:ok, result} -> IO.puts("Result: \#{result}")
        {:error, reason} -> IO.puts("Error: \#{inspect(reason)}")
      end

  ## Options

  - `:tools` - List of tool modules available to the LLM (default: [])
  - `:max_iterations` - Maximum number of iterations before giving up (default: 3)
  - `:system_prompt` - Custom system prompt (default: problem-solving assistant prompt)
  - `:temperature` - LLM temperature for response generation (default: 1.0)

  ## Completion Indicators

  The solver monitors the LLM's responses for these keywords:
  - "DONE" (case-insensitive) - Task completed successfully
  - "FAIL" (case-insensitive) - Task cannot be completed

  When either indicator is detected, the solver requests a final summary
  and returns that to the caller.
  """

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.ChatSession

  require Logger

  @type t :: %__MODULE__{
          broker: Broker.t(),
          tools: [module()],
          max_iterations: pos_integer(),
          system_prompt: String.t(),
          temperature: float()
        }

  @enforce_keys [:broker]
  defstruct [
    :broker,
    tools: [],
    max_iterations: 3,
    system_prompt: """
    You are a problem-solving assistant that can solve complex problems step by step.
    You analyze problems, break them down into smaller parts, and solve them systematically.
    If you cannot solve a problem completely in one step, you make progress and identify what to do next.
    """,
    temperature: 1.0
  ]

  @default_system_prompt """
  You are a problem-solving assistant that can solve complex problems step by step.
  You analyze problems, break them down into smaller parts, and solve them systematically.
  If you cannot solve a problem completely in one step, you make progress and identify what to do next.
  """

  @doc """
  Creates a new IterativeProblemSolver.

  ## Parameters

  - `broker` - The LLM broker to use for generating responses
  - `opts` - Keyword list of options:
    - `:tools` - List of tool modules (default: [])
    - `:max_iterations` - Maximum iterations (default: 3)
    - `:system_prompt` - Custom system prompt (default: problem-solving prompt)
    - `:temperature` - LLM temperature (default: 1.0)

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)

      # With defaults
      solver = IterativeProblemSolver.new(broker)

      # With custom options
      solver = IterativeProblemSolver.new(broker,
        tools: [MyTool],
        max_iterations: 5,
        system_prompt: "You are a specialized assistant.",
        temperature: 0.7
      )

  """
  @spec new(Broker.t(), keyword()) :: t()
  def new(broker, opts \\ []) do
    %__MODULE__{
      broker: broker,
      tools: Keyword.get(opts, :tools, []),
      max_iterations: Keyword.get(opts, :max_iterations, 3),
      system_prompt: Keyword.get(opts, :system_prompt, @default_system_prompt),
      temperature: Keyword.get(opts, :temperature, 1.0)
    }
  end

  @doc """
  Executes the problem-solving process.

  This method runs the iterative problem-solving process, continuing until one of
  these conditions is met:
  - The task is completed successfully ("DONE")
  - The task fails explicitly ("FAIL")
  - The maximum number of iterations is reached

  After the loop completes, the solver requests a summary of the final result,
  excluding process details.

  ## Parameters

  - `solver` - The IterativeProblemSolver instance
  - `problem` - The problem or request to be solved

  ## Returns

  - `{:ok, summary}` - Success with final result summary
  - `{:error, reason}` - Error from broker or chat session

  ## Examples

      {:ok, result} = IterativeProblemSolver.solve(solver, "Calculate the area of a circle with radius 5")
      # => {:ok, "The area is approximately 78.54 square units."}

      {:ok, result} = IterativeProblemSolver.solve(solver, "What's the weather tomorrow?")
      # Uses tools iteratively to gather info and answer

  """
  @spec solve(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def solve(solver, problem) do
    # Create a chat session for this problem-solving attempt
    session =
      ChatSession.new(solver.broker,
        system_prompt: solver.system_prompt,
        tools: solver.tools,
        temperature: solver.temperature
      )

    case run_iterations(session, problem, solver.max_iterations) do
      {:ok, session, :completed, result} ->
        Logger.info("Task completed",
          user_request: problem,
          result: result,
          reason: :done
        )

        get_final_summary(session)

      {:ok, session, :failed, result} ->
        Logger.info("Task failed",
          user_request: problem,
          result: result,
          reason: :fail
        )

        get_final_summary(session)

      {:ok, session, :max_iterations, result} ->
        Logger.info("Max iterations reached",
          max_iterations: solver.max_iterations,
          user_request: problem,
          result: result
        )

        get_final_summary(session)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  # Run iterations until completion, failure, or max iterations
  defp run_iterations(session, problem, iterations_remaining) when iterations_remaining > 0 do
    case step(session, problem) do
      {:ok, result, updated_session} ->
        result_lower = String.downcase(result)

        cond do
          # Use word boundary regex to avoid false matches in words like "failed", "unfailing"
          Regex.match?(~r/\bfail\b/, result_lower) ->
            {:ok, updated_session, :failed, result}

          # Use word boundary regex to avoid false matches in words like "abandoned", "undone"
          Regex.match?(~r/\bdone\b/, result_lower) ->
            {:ok, updated_session, :completed, result}

          true ->
            run_iterations(updated_session, problem, iterations_remaining - 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_iterations(session, _problem, 0) do
    # Max iterations reached, get the last message content if available
    last_result =
      case List.last(session.messages) do
        nil -> ""
        msg -> msg.message.content || ""
      end

    {:ok, session, :max_iterations, last_result}
  end

  # Execute a single problem-solving step
  defp step(session, problem) do
    prompt = """
    Given the user request:
    #{problem}

    Use the tools at your disposal to act on their request. You may wish to create a step-by-step plan for more complicated requests.

    If you cannot provide an answer, say only "FAIL".
    If you have the answer, say only "DONE".
    """

    ChatSession.send(session, prompt)
  end

  # Request final summary from the LLM
  defp get_final_summary(session) do
    summary_prompt =
      "Summarize the final result, and only the final result, without commenting on the process by which you achieved it."

    case ChatSession.send(session, summary_prompt) do
      {:ok, summary, _session} ->
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
