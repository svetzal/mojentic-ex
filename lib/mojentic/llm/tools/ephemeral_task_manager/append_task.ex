defmodule Mojentic.LLM.Tools.EphemeralTaskManager.AppendTask do
  @moduledoc """
  Tool for appending a new task to the end of the ephemeral task manager list.

  This module creates a wrapper that holds a reference to the shared task list agent.

  ## Examples

      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      tool = Mojentic.LLM.Tools.EphemeralTaskManager.AppendTask.new(agent)
      {:ok, result} = tool.run(%{"description" => "My task"})

  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.{Task, TaskList}

  defstruct [:agent]

  @doc """
  Creates a new AppendTask tool with the given agent.
  """
  def new(agent) do
    %__MODULE__{agent: agent}
  end

  @impl true
  def run(%__MODULE__{agent: agent}, arguments) do
    description = Map.get(arguments, "description", "")

    try do
      {task, _updated_list} =
        Agent.get_and_update(agent, fn task_list ->
          {task, updated_list} = TaskList.append_task(task_list, description)
          {{task, updated_list}, updated_list}
        end)

      {:ok,
       %{
         id: task.id,
         description: task.description,
         status: Task.status_to_string(task.status),
         summary: "Task '#{task.id}' appended successfully"
       }}
    rescue
      e ->
        {:error,
         %{
           error: Exception.message(e),
           summary: "Failed to append task: #{Exception.message(e)}"
         }}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "append_task",
        description:
          "Append a new task to the end of the task list with a description. The task will start with 'pending' status.",
        parameters: %{
          type: "object",
          properties: %{
            description: %{
              type: "string",
              description: "The description of the task"
            }
          },
          required: ["description"]
        }
      }
    }
  end
end
