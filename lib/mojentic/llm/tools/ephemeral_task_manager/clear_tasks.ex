defmodule Mojentic.LLM.Tools.EphemeralTaskManager.ClearTasks do
  @moduledoc """
  Tool for clearing all tasks from the ephemeral task manager.
  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

  defstruct [:agent]

  @doc """
  Creates a new ClearTasks tool with the given agent.
  """
  def new(agent) do
    %__MODULE__{agent: agent}
  end

  @impl true
  def run(%__MODULE__{agent: agent}, _arguments) do
    {count, _updated_list} =
      Agent.get_and_update(agent, fn task_list ->
        {count, updated_list} = TaskList.clear_tasks(task_list)
        {{count, updated_list}, updated_list}
      end)

    {:ok,
     %{
       count: count,
       summary: "Cleared #{count} tasks from the list"
     }}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "clear_tasks",
        description: "Remove all tasks from the task list.",
        parameters: %{
          type: "object",
          properties: %{}
        }
      }
    }
  end
end
