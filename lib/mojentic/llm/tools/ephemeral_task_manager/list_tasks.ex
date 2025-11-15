defmodule Mojentic.LLM.Tools.EphemeralTaskManager.ListTasks do
  @moduledoc """
  Tool for listing all tasks in the ephemeral task manager.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.{Task, TaskList}

  defstruct [:agent]

  @doc """
  Creates a new ListTasks tool with the given agent.
  """
  def new(agent) do
    %__MODULE__{agent: agent}
  end

  @impl true
  def run(%__MODULE__{agent: agent}, _arguments) do
    tasks = Agent.get(agent, &TaskList.list_tasks/1)
    task_list_str = format_tasks(tasks)

    {:ok,
     %{
       count: length(tasks),
       tasks: task_list_str,
       summary: "Found #{length(tasks)} tasks\n\n#{task_list_str}"
     }}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "list_tasks",
        description: "List all tasks in the task list.",
        parameters: %{
          type: "object",
          properties: %{}
        }
      }
    }
  end

  defp format_tasks([]) do
    "No tasks found."
  end

  defp format_tasks(tasks) do
    tasks
    |> Enum.map(fn task ->
      "#{task.id}. #{task.description} (#{Task.status_to_string(task.status)})"
    end)
    |> Enum.join("\n")
  end
end
