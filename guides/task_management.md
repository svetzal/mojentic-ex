# Example: Task Management

The `Mojentic.LLM.Tools.TaskManager` is an example of how to build stateful tools that allow agents to manage ephemeral tasks. This reference implementation shows how to maintain state across tool calls.

## Features

- **Create Tasks**: Add new tasks to the list
- **List Tasks**: View all current tasks and their status
- **Complete Tasks**: Mark tasks as done
- **Prioritize**: Agents can determine the order of execution

## Usage

```elixir
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Tools.TaskManager

# Initialize broker
broker = Broker.new("qwen3:32b", Mojentic.LLM.Gateways.Ollama)

# Register the tool
tools = [TaskManager]

# The agent can now manage its own tasks
messages = [
  Mojentic.LLM.Message.system("You are a helpful assistant. Use the task manager to track your work."),
  Mojentic.LLM.Message.user("Plan a party for 10 people.")
]

{:ok, response} = Broker.generate(broker, messages, tools)
```

## Integration with Agents

The Task Manager is particularly powerful when combined with the `IterativeProblemSolver` agent, allowing it to maintain state across multiple reasoning steps.
