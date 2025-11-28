# Task Management

The `Mojentic.LLM.Tools.TaskManager` tool allows agents to manage ephemeral tasks during their execution. This is useful for breaking down complex goals into smaller, trackable steps.

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
