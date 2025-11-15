defmodule Mojentic.LLM.Tools.EphemeralTaskManager.CompleteTask do
  @moduledoc """
  Tool for completing a task in the ephemeral task manager.

  This tool changes a task's status from :in_progress to :completed.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.{Task, TaskList}

  defstruct [:agent]

  @doc """
  Creates a new CompleteTask tool with the given agent.
  """
  def new(agent) do
    %__MODULE__{agent: agent}
  end

  @impl true
  def run(%__MODULE__{agent: agent}, arguments) do
    task_id_arg = Map.get(arguments, "id")

    # Convert to integer if it's a string
    task_id =
      case task_id_arg do
        id when is_integer(id) -> id
        id when is_binary(id) -> String.to_integer(id)
        _ -> task_id_arg
      end

    try do
      result =
        Agent.get_and_update(agent, fn task_list ->
          case TaskList.complete_task(task_list, task_id) do
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
             summary: "Task '#{task_id}' completed successfully"
           }}

        {:error, reason} ->
          {:error,
           %{
             error: reason,
             summary: "Failed to complete task: #{reason}"
           }}
      end
    rescue
      e ->
        {:error,
         %{
           error: Exception.message(e),
           summary: "Failed to complete task: #{Exception.message(e)}"
         }}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "complete_task",
        description: "Complete a task by changing its status from IN_PROGRESS to COMPLETED.",
        parameters: %{
          type: "object",
          properties: %{
            id: %{
              type: "integer",
              description: "The ID of the task to complete"
            }
          },
          required: ["id"]
        }
      }
    }
  end
end
