#!/usr/bin/env elixir

# Example demonstrating the use of all file management tools with task management.
#
# This example creates a sandbox directory and equips an LLM with access to:
# - File management tools (read, write, list, find, create directories)
# - Task management tools (for planning and tracking work)
#
# The LLM is then given a coding task that requires using these tools to
# create a small Python project with tests.
#
# Run with: mix run examples/coding_file_tool.exs

Mix.install([
  {:mojentic, path: Path.expand("../")}
])

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

alias Mojentic.LLM.Tools.{
  FilesystemGateway,
  ListFilesTool,
  ReadFileTool,
  WriteFileTool,
  ListAllFilesTool,
  FindFilesByGlobTool,
  FindFilesContainingTool,
  FindLinesMatchingTool,
  CreateDirectoryTool
}

alias Mojentic.LLM.Tools.EphemeralTaskManager
alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

# Create a sandbox directory for the coding project
sandbox_dir = System.tmp_dir!() |> Path.join("mojentic_coding_example")
File.rm_rf!(sandbox_dir)
File.mkdir_p!(sandbox_dir)

IO.puts("=" <> String.duplicate("=", 79))
IO.puts("Coding File Tool Example")
IO.puts("=" <> String.duplicate("=", 79))
IO.puts("")
IO.puts("Sandbox directory: #{sandbox_dir}")
IO.puts("")

# Create FilesystemGateway and file management tools
{:ok, fs} = FilesystemGateway.new(sandbox_dir)

file_tools = [
  ListFilesTool.new(fs),
  ReadFileTool.new(fs),
  WriteFileTool.new(fs),
  ListAllFilesTool.new(fs),
  FindFilesByGlobTool.new(fs),
  FindFilesContainingTool.new(fs),
  FindLinesMatchingTool.new(fs),
  CreateDirectoryTool.new(fs)
]

# Create task management tools
{:ok, task_agent} = Agent.start_link(fn -> TaskList.new() end)
task_tools = EphemeralTaskManager.all_tools(task_agent)

# Combine all tools
all_tools = file_tools ++ task_tools

# Create LLM broker with qwen3-coder model for coding tasks
{:ok, gateway} = Ollama.new()
broker = Broker.new("qwen3-coder:30b", gateway)

# System prompt with coding best practices
system_prompt = """
# Role and Context

You are an expert and principled software engineer, well versed in writing Python programs.
You work carefully and purposefully and always check your work with an eye to testability
and correctness. You know that every line of code you write is a liability, and you take
care that every line matters.

# Universal Engineering Principles

* **Code is communication** — optimise for the next human reader.
* **Simple Design Heuristics**:
  1. **All tests pass** — correctness is non-negotiable.
  2. **Reveals intent** — code should read like an explanation.
  3. **No knowledge duplication** — avoid multiple spots that must change together.
  4. **Minimal entities** — remove unnecessary indirection or classes.
* **Small, safe increments** — single-reason commits; avoid speculative work (YAGNI).
* **Tests are the executable spec** — test behaviour not implementation.
* **Functional core, imperative shell** — isolate pure logic from I/O and side effects.

# Planning and Goal Tracking

- Use the task management tools to create your plans and work through them step by step.
- Before declaring yourself finished, list all tasks and ensure they are all complete.
- If you've missed or forgotten steps, add them to the task list and continue.
- When all tasks are complete, and you can think of no more to add, declare yourself finished.

# File Management

- All file operations must be done through the provided tools.
- The sandbox root is: #{sandbox_dir}
- Use relative paths from the sandbox root (e.g., "src/main.py", not absolute paths).
- Always verify your work by reading back files you create or modify.

# Task Instructions

Work systematically:
1. Break down the problem into clear tasks
2. Create the task list using task management tools
3. Work through each task one by one
4. Mark tasks complete as you finish them
5. Verify your work at each step
"""

# Define the coding task
task = """
Create a simple Python calculator module with the following features:

1. A Calculator class with basic operations (add, subtract, multiply, divide)
2. Proper error handling for division by zero
3. A comprehensive test file using pytest that tests all operations
4. A README.md explaining how to use the calculator

Keep it simple but well-structured and properly tested.
"""

IO.puts("Task assigned to LLM:")
IO.puts(task)
IO.puts("")
IO.puts("Working on task...")
IO.puts("-" <> String.duplicate("-", 79))
IO.puts("")

messages = [
  Message.system(system_prompt),
  Message.user(task)
]

# Generate response with streaming to show progress
case Broker.generate(broker, messages, all_tools, temperature: 0.1) do
  {:ok, response} ->
    IO.puts("")
    IO.puts("-" <> String.duplicate("-", 79))
    IO.puts("LLM Response:")
    IO.puts(response.content)

  {:error, reason} ->
    IO.puts("")
    IO.puts("Error: #{inspect(reason)}")
end

IO.puts("")
IO.puts("=" <> String.duplicate("=", 79))
IO.puts("Final Results")
IO.puts("=" <> String.duplicate("=", 79))
IO.puts("")

# Show final task list
tasks = Agent.get(task_agent, &TaskList.list_tasks/1)

IO.puts("Task List Status:")
if Enum.empty?(tasks) do
  IO.puts("  No tasks in list")
else
  Enum.each(tasks, fn task ->
    status_str = Mojentic.LLM.Tools.EphemeralTaskManager.Task.status_to_string(task.status)
    IO.puts("  #{task.id}. #{task.description} (#{status_str})")
  end)
end

IO.puts("")

# Show created files
IO.puts("Files created:")
{:ok, all_files} = FilesystemGateway.list_all_files(fs, ".")

if Enum.empty?(all_files) do
  IO.puts("  No files created")
else
  Enum.each(all_files, fn file ->
    IO.puts("  - #{file}")
  end)
end

IO.puts("")
IO.puts("Sandbox directory preserved at: #{sandbox_dir}")
IO.puts("You can inspect the generated code and run tests with:")
IO.puts("  cd #{sandbox_dir}")
IO.puts("  pytest test_calculator.py  # (if pytest is installed)")
IO.puts("")

# Clean up
Agent.stop(task_agent)

IO.puts("Done!")
