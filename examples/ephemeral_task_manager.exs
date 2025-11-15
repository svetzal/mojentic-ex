#!/usr/bin/env elixir

# Example demonstrating the usage of the ephemeral task manager tools.
#
# Run with: mix run examples/ephemeral_task_manager.exs

Mix.install([
  {:mojentic, path: Path.expand("../")}
])

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.EphemeralTaskManager
alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

# Create broker
broker = Broker.new("qwen3:32b", Ollama)

# Create shared task list agent
{:ok, agent} = Agent.start_link(fn -> TaskList.new() end)

# Create all task management tools
tools = EphemeralTaskManager.all_tools(agent)

# Ask the LLM to manage a counting task
message =
  Message.user("""
  I want you to count from 1 to 5. Break that request down into individual tasks,
  track them using available tools, and perform them one by one until you're finished.
  Report on your progress as you work through the tasks.
  """)

IO.puts("Starting task management example...")
IO.puts("=" <> String.duplicate("=", 79))
IO.puts("")

case Broker.generate(broker, [message], tools, temperature: 0.0) do
  {:ok, response} ->
    IO.puts("LLM Response:")
    IO.puts(response.content)
    IO.puts("")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# Show final task list
tasks = Agent.get(agent, &TaskList.list_tasks/1)

IO.puts("")
IO.puts("=" <> String.duplicate("=", 80))
IO.puts("Final Task List:")
IO.puts("")

if Enum.empty?(tasks) do
  IO.puts("No tasks in list")
else
  Enum.each(tasks, fn task ->
    status_str = Mojentic.LLM.Tools.EphemeralTaskManager.Task.status_to_string(task.status)
    IO.puts("#{task.id}. #{task.description} (#{status_str})")
  end)
end

# Clean up
Agent.stop(agent)
