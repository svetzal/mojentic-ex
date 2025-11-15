defmodule Mojentic.LLM.Tools.EphemeralTaskManager.InsertTaskAfter do
  @moduledoc """
  Tool for inserting a new task after an existing task in the ephemeral task manager list.

  This tool wraps a TaskList agent process that manages the shared task state.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.Task
  alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

  defstruct [:agent]

  @doc """
  Creates a new InsertTaskAfter tool with the given agent.
  """
  def new(agent) do
    %__MODULE__{agent: agent}
  end

  @impl true
  def run(%__MODULE__{agent: agent}, arguments) do
    existing_task_id = Map.get(arguments, "existing_task_id")
    description = Map.get(arguments, "description", "")

    # Convert to integer if it's a string
    task_id =
      case existing_task_id do
        id when is_integer(id) -> id
        id when is_binary(id) -> String.to_integer(id)
        _ -> existing_task_id
      end

    try do
      result =
        Agent.get_and_update(agent, fn task_list ->
          case TaskList.insert_task_after(task_list, task_id, description) do
            {:ok, task, updated_list} ->
              {{:ok, task}, updated_list}

            {:error, reason} ->
              {{:error, reason}, task_list}
          end
        end)

      case result do
        {:ok, task} ->
          {:ok,
           %{
             id: task.id,
             description: task.description,
             status: Task.status_to_string(task.status),
             summary: "Task '#{task.id}' inserted after task '#{existing_task_id}' successfully"
           }}

        {:error, reason} ->
          {:error,
           %{
             error: reason,
             summary: "Failed to insert task: #{reason}"
           }}
      end
    rescue
      e ->
        {:error,
         %{
           error: Exception.message(e),
           summary: "Failed to insert task: #{Exception.message(e)}"
         }}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "insert_task_after",
        description:
          "Insert a new task after an existing task in the task list. The task will start with 'pending' status.",
        parameters: %{
          type: "object",
          properties: %{
            existing_task_id: %{
              type: "integer",
              description: "The ID of the existing task after which to insert the new task"
            },
            description: %{
              type: "string",
              description: "The description of the new task"
            }
          },
          required: ["existing_task_id", "description"]
        }
      }
    }
  end
end
