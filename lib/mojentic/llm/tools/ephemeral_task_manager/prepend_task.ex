defmodule Mojentic.LLM.Tools.EphemeralTaskManager.PrependTask do
  @moduledoc """
  Tool for prepending a new task to the beginning of the ephemeral task manager list.

  This tool wraps a TaskList agent process that manages the shared task state.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.Task
  alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

  defstruct [:agent]

  @doc """
  Creates a new PrependTask tool with the given agent.
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
          {task, updated_list} = TaskList.prepend_task(task_list, description)
          {{task, updated_list}, updated_list}
        end)

      {:ok,
       %{
         id: task.id,
         description: task.description,
         status: Task.status_to_string(task.status),
         summary: "Task '#{task.id}' prepended successfully"
       }}
    rescue
      e ->
        {:error,
         %{
           error: Exception.message(e),
           summary: "Failed to prepend task: #{Exception.message(e)}"
         }}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "prepend_task",
        description:
          "Prepend a new task to the beginning of the task list with a description. The task will start with 'pending' status.",
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
