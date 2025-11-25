# ReAct Pattern Example

This example demonstrates the **Reasoning and Acting (ReAct)** pattern implementation in Elixir, following the reference Python implementation from `mojentic-py/src/_examples/react/`.

## Overview

The ReAct pattern is an iterative problem-solving approach where agents:
1. **Think** - Create plans to solve user queries
2. **Decide** - Determine the next action (plan, act, or finish)
3. **Act** - Execute tools to gather information
4. **Summarize** - Generate final answers based on accumulated context

## Architecture

The implementation uses an event-driven architecture with the following components:

### Data Models (`lib/mojentic/examples/react/models.ex`)

- **NextAction** - Enum for possible actions: `:plan`, `:act`, `:finish`
- **ThoughtActionObservation** - Records thought, action, and observation for each step
- **Plan** - Contains a list of steps to solve the query
- **CurrentContext** - Maintains the complete state: user query, plan, history, iteration count

### Events (`lib/mojentic/examples/react/events.ex`)

- **InvokeThinking** - Triggers the planning phase
- **InvokeDecisioning** - Triggers the decision-making phase
- **InvokeToolCall** - Triggers tool execution
- **FinishAndSummarize** - Triggers the final answer generation
- **FailureOccurred** - Signals errors or failures

### Agents

#### ThinkingAgent (`lib/mojentic/examples/react/thinking_agent.ex`)
Creates structured plans using an LLM to analyze the problem and break it into actionable steps.

#### DecisioningAgent (`lib/mojentic/examples/react/decisioning_agent.ex`)
Evaluates the current context to decide whether to:
- Create/refine a plan (PLAN)
- Execute a tool (ACT)
- Generate the final answer (FINISH)

Includes a maximum iteration limit (10) to prevent infinite loops.

#### ToolCallAgent (`lib/mojentic/examples/react/tool_call_agent.ex`)
Executes tools with provided arguments and captures results in the context history.

#### SummarizationAgent (`lib/mojentic/examples/react/summarization_agent.ex`)
Generates the final answer by synthesizing all gathered information.

#### OutputAgent (`lib/mojentic/examples/react/output_agent.ex`)
Logs all events for observability and debugging.

### Utilities (`lib/mojentic/examples/react/formatters.ex`)

Helper functions for formatting context and tool information into human-readable strings for LLM prompts.

## Running the Example

```bash
# From the mojentic-ex directory
elixir examples/react.exs
```

### Requirements

- Elixir 1.14+
- Ollama running locally with a compatible model (e.g., `qwen3:8b`)
- Internet connection for initial dependency download

### Expected Output

The example will:
1. Create a plan to answer "What is the date next Friday?"
2. Decide to use the `resolve_date` tool
3. Execute the tool to resolve the date
4. Decide to finish
5. Generate a final answer with the resolved date

## Example Flow

```
User Query: "What is the date next Friday?"
    ↓
InvokeThinking → Creates plan with steps
    ↓
InvokeDecisioning → Decides to ACT
    ↓
InvokeToolCall → Executes resolve_date tool
    ↓
InvokeDecisioning → Decides to FINISH
    ↓
FinishAndSummarize → Generates final answer
```

## Testing

```bash
# Run ReAct tests
mix test test/mojentic/examples/react/

# Run all tests
mix test
```

### Test Coverage

- **models_test.exs** - Tests for data structures
- **events_test.exs** - Tests for event types
- **formatters_test.exs** - Tests for formatting utilities
- **tool_call_agent_test.exs** - Tests for tool execution
- **output_agent_test.exs** - Tests for event logging

## Key Differences from Python Implementation

### 1. **Struct-based Data Models**
Elixir uses structs with enforced keys instead of Pydantic models:

```elixir
defmodule CurrentContext do
  @enforce_keys [:user_query]
  defstruct [:user_query, plan: %Plan{}, history: [], iteration: 0]
end
```

### 2. **Pattern Matching**
Leverages Elixir's pattern matching for event routing:

```elixir
def receive_event_async(_broker, %InvokeToolCall{} = event) do
  # Handle tool call
end

def receive_event_async(_broker, _event), do: {:ok, []}
```

### 3. **OTP and GenServer**
Uses the AsyncDispatcher (GenServer) for event processing instead of Python's synchronous dispatcher.

### 4. **Function Clauses**
Multiple function clauses with guards instead of if/elif chains:

```elixir
defp extract_result_text(result) when is_binary(result), do: result
defp extract_result_text(result) when is_map(result), do: # ...
```

### 5. **Tuple Return Values**
Follows Elixir conventions with `{:ok, result}` or `{:error, reason}` tuples.

## Architecture Patterns

### Functional Core, Imperative Shell
- **Pure functions** for formatting, data transformation
- **Side effects** isolated in agent boundaries (LLM calls, I/O)

### Event-Driven Architecture
- Agents communicate via immutable events
- Router maps event types to handlers
- Async dispatcher manages event flow

### Behaviours for Contracts
- `BaseAsyncAgent` behaviour defines agent interface
- Wrapper modules adapt core agents to the behaviour

## Configuration

### Model Selection
Edit `examples/react.exs` to change the LLM model:

```elixir
broker = Broker.new("qwen3:8b", Ollama)  # Change model here
```

### Iteration Limit
Edit `lib/mojentic/examples/react/decisioning_agent.ex`:

```elixir
@max_iterations 10  # Adjust as needed
```

### Timeout
Edit `examples/react.exs` to adjust the wait timeout:

```elixir
:ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 120_000)
```

## Troubleshooting

### Timeout Errors
- Increase timeout in `examples/react.exs`
- Check Ollama is running: `ollama list`
- Try a smaller/faster model

### Model Not Found
- List available models: `ollama list`
- Pull a model: `ollama pull qwen3:8b`
- Update model name in `examples/react.exs`

### Compilation Warnings
Run `mix format` to ensure code is properly formatted.

## Code Quality

The implementation adheres to:
- ✅ **Zero Credo warnings** in React code
- ✅ **100% test coverage** for pure functions
- ✅ **Comprehensive documentation** with `@moduledoc` and `@doc`
- ✅ **Idiomatic Elixir** patterns and conventions

## Further Reading

- [ReAct Pattern Paper](https://arxiv.org/abs/2210.03629)
- [Mojentic Documentation](../README.md)
- [Python Reference Implementation](../../mojentic-py/src/_examples/react/)
