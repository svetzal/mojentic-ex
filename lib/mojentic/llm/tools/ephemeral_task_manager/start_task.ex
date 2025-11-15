defmodule Mojentic.LLM.Tools.EphemeralTaskManager.StartTask do
  @moduledoc """
  Tool for starting a task in the ephemeral task manager.

  This tool changes a task's status from :pending to :in_progress.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.{Task, TaskList}

  defstruct [:agent]

  @doc """
  Creates a new StartTask tool with the given agent.
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
          case TaskList.start_task(task_list, task_id) do
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
             summary: "Task '#{task_id}' started successfully"
           }}

        {:error, reason} ->
          {:error,
           %{
             error: reason,
             summary: "Failed to start task: #{reason}"
           }}
      end
    rescue
      e ->
        {:error,
         %{
           error: Exception.message(e),
           summary: "Failed to start task: #{Exception.message(e)}"
         }}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "start_task",
        description: "Start a task by changing its status from PENDING to IN_PROGRESS.",
        parameters: %{
          type: "object",
          properties: %{
            id: %{
              type: "integer",
              description: "The ID of the task to start"
            }
          },
          required: ["id"]
        }
      }
    }
  end
end
