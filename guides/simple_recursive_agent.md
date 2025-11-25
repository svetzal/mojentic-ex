# Simple Recursive Agent

The `SimpleRecursiveAgent` provides an event-driven approach to iterative problem-solving with LLMs. It automatically handles retries, tool execution, and state management while emitting events at each step for monitoring.

## Overview

The SimpleRecursiveAgent:
- Solves problems through iterative refinement
- Emits events at each step for monitoring and debugging
- Handles tool execution automatically via ChatSession
- Stops when it finds a solution, fails, or reaches max iterations
- Provides timeout protection (300 seconds default)

## Basic Usage

```elixir
alias Mojentic.Agents.SimpleRecursiveAgent
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

# Create broker
{:ok, gateway} = Ollama.new()
broker = Broker.new("qwen3:32b", gateway)

# Create agent with 5 max iterations
agent = SimpleRecursiveAgent.new(broker, [], 5)

# Solve a problem
{:ok, solution} = SimpleRecursiveAgent.solve(agent, "What is the capital of France?")
IO.puts(solution)
```

## With Tools

The agent can use tools to gather information or perform actions:

```elixir
alias Mojentic.LLM.Tools.DateResolver

date_tool = DateResolver.new()

agent = SimpleRecursiveAgent.new(
  broker,
  [date_tool],  # Tools available to the agent
  5             # Max iterations
)

{:ok, solution} = SimpleRecursiveAgent.solve(agent, "What's the date next Friday?")
```

## Event Monitoring

Subscribe to events to monitor the problem-solving process:

```elixir
alias Mojentic.Agents.SimpleRecursiveAgent

agent = SimpleRecursiveAgent.new(broker, [], 5)

# Subscribe to events
pid = self()

subscribe_fn = fn event ->
  case event do
    {:goal_submitted, goal} ->
      IO.puts("Goal submitted: #{goal}")

    {:iteration_completed, iteration, response, _state} ->
      IO.puts("Iteration #{iteration}: #{response}")

    {:goal_achieved, solution, iterations} ->
      IO.puts("Success after #{iterations} iterations!")

    {:goal_failed, reason} ->
      IO.puts("Failed: #{reason}")

    {:timeout} ->
      IO.puts("Timeout after 300 seconds")
  end
end

# Subscribe before solving
SimpleRecursiveAgent.subscribe(agent, subscribe_fn)

# Solve the problem
{:ok, solution} = SimpleRecursiveAgent.solve(agent, "Complex problem")

# Unsubscribe when done
SimpleRecursiveAgent.unsubscribe(agent, subscribe_fn)
```

## Custom System Prompt

Customize the agent's behavior with a custom system prompt:

```elixir
custom_prompt = """
You are a concise assistant that provides brief, factual answers.
Always respond in exactly one sentence.
"""

agent = SimpleRecursiveAgent.new(
  broker,
  [],
  5,
  custom_prompt
)
```

## Goal State

The state struct that tracks the problem-solving process:

```elixir
%SimpleRecursiveAgent.GoalState{
  goal: "Problem to solve",
  iteration: 0,
  max_iterations: 5,
  solution: nil,
  is_complete: false
}
```

## Event Types

Events are tuples sent to subscribers:

- `{:goal_submitted, goal}` - When a problem is submitted
- `{:iteration_completed, iteration, response, state}` - After each iteration
- `{:goal_achieved, solution, iterations}` - When successfully solved
- `{:goal_failed, reason}` - When the goal cannot be solved
- `{:timeout}` - If solving exceeds 300 seconds

## Completion Criteria

The agent stops iterating when:

1. **Success**: The LLM response contains "DONE" (case-insensitive)
2. **Failure**: The LLM response contains "FAIL" (case-insensitive)
3. **Max Iterations**: The iteration count reaches `max_iterations`
4. **Timeout**: 300 seconds have elapsed

When stopped at max iterations, the last response is returned as the best available solution.

## API Reference

### SimpleRecursiveAgent.new/4

```elixir
@spec new(
  broker :: Broker.t(),
  available_tools :: [Tool.t()],
  max_iterations :: pos_integer(),
  system_prompt :: String.t() | nil
) :: t()
```

**Parameters:**
- `broker`: The LLM broker to use for generating responses
- `available_tools`: List of tools the agent can use (default: `[]`)
- `max_iterations`: Maximum number of iterations (default: `5`)
- `system_prompt`: Custom system prompt (default: problem-solving assistant prompt)

### SimpleRecursiveAgent.solve/2

```elixir
@spec solve(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
```

Solve a problem asynchronously.

**Parameters:**
- `agent`: The SimpleRecursiveAgent struct
- `problem`: The problem to solve

**Returns:** `{:ok, solution}` or `{:error, reason}`

### SimpleRecursiveAgent.subscribe/2

```elixir
@spec subscribe(t(), function()) :: :ok
```

Subscribe to agent events.

**Parameters:**
- `agent`: The SimpleRecursiveAgent struct
- `callback`: Function to call when events occur

### SimpleRecursiveAgent.unsubscribe/2

```elixir
@spec unsubscribe(t(), function()) :: :ok
```

Unsubscribe from events.

## Best Practices

1. **Pattern match on results**: Always handle both success and error cases:
   ```elixir
   case SimpleRecursiveAgent.solve(agent, problem) do
     {:ok, solution} -> IO.puts(solution)
     {:error, reason} -> Logger.error("Failed: #{inspect(reason)}")
   end
   ```

2. **Set appropriate max iterations**: Balance between thoroughness and performance:
   - Simple queries: 3-5 iterations
   - Complex problems: 10-20 iterations

3. **Use event monitoring for debugging**: Subscribe to events during development to understand the agent's reasoning process

4. **Provide clear problem statements**: The more specific your problem description, the better the agent can solve it

5. **Guide with system prompts**: Use custom system prompts to shape the agent's approach to problem-solving

## Example: Complete Workflow

```elixir
alias Mojentic.Agents.SimpleRecursiveAgent
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.DateResolver

defmodule ProblemSolver do
  def run do
    # Setup
    {:ok, gateway} = Ollama.new()
    broker = Broker.new("qwen3:32b", gateway)

    date_tool = DateResolver.new()
    agent = SimpleRecursiveAgent.new(broker, [date_tool], 5)

    # Subscribe to events
    SimpleRecursiveAgent.subscribe(agent, fn event ->
      case event do
        {:iteration_completed, iteration, _response, state} ->
          IO.puts("Iteration #{iteration}/#{state.max_iterations}")

        {:goal_achieved, _solution, iterations} ->
          IO.puts("✓ Solved in #{iterations} iterations")

        _ ->
          :ok
      end
    end)

    # Solve problem
    case SimpleRecursiveAgent.solve(agent, "What's the date two Fridays from now?") do
      {:ok, solution} ->
        IO.puts("\nSolution: #{solution}")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end
end

ProblemSolver.run()
```

## Concurrent Problem Solving

The agent is designed to handle multiple problems concurrently using OTP patterns:

```elixir
alias Mojentic.Agents.SimpleRecursiveAgent

agent = SimpleRecursiveAgent.new(broker, [], 3)

problems = [
  "What is the Pythagorean theorem?",
  "Explain recursion in programming."
]

# Solve all problems concurrently
tasks = Enum.map(problems, fn problem ->
  Task.async(fn ->
    SimpleRecursiveAgent.solve(agent, problem)
  end)
end)

# Wait for all results
results = Task.await_many(tasks, 60_000)

# Display results
Enum.each(Enum.with_index(results, 1), fn {{:ok, solution}, i} ->
  IO.puts("Problem #{i}: #{solution}")
end)
```

## Comparison with IterativeProblemSolver

Both agents solve problems iteratively, but they differ in approach:

**SimpleRecursiveAgent:**
- Event-driven architecture
- Explicit event types for each stage
- Manual event subscription for monitoring
- 300-second hard timeout
- Best for: Custom event handling, complex workflows, debugging

**IterativeProblemSolver:**
- Simpler API, minimal boilerplate
- Direct access to chat history
- Best for: Quick prototyping, straightforward tasks

Choose `SimpleRecursiveAgent` when you need fine-grained control and visibility into the problem-solving process. Choose `IterativeProblemSolver` for simpler use cases.

## Integration with GenServer

For stateful applications, wrap the agent in a GenServer:

```elixir
defmodule MyApp.ProblemSolver do
  use GenServer
  alias Mojentic.Agents.SimpleRecursiveAgent

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    agent = SimpleRecursiveAgent.new(
      opts[:broker],
      opts[:tools] || [],
      opts[:max_iterations] || 5
    )

    {:ok, %{agent: agent}}
  end

  def handle_call({:solve, problem}, _from, state) do
    case SimpleRecursiveAgent.solve(state.agent, problem) do
      {:ok, solution} -> {:reply, {:ok, solution}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end

# Usage
MyApp.ProblemSolver.start_link(broker: broker, tools: [date_tool])
{:ok, solution} = GenServer.call(MyApp.ProblemSolver, {:solve, "What is 2+2?"})
```

## Testing

The SimpleRecursiveAgent includes comprehensive tests demonstrating all features. Run tests with:

```bash
mix test test/mojentic/agents/simple_recursive_agent_test.exs
```

See the test file for examples of:
- Event monitoring
- Tool integration
- Timeout handling
- Max iteration limits
- Success and failure scenarios
