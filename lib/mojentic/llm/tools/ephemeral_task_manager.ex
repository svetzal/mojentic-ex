defmodule Mojentic.LLM.Tools.EphemeralTaskManager do
  @moduledoc """
  Ephemeral Task Manager tools for managing a list of tasks.

  This module provides tools for appending, prepending, inserting, starting,
  completing, and listing tasks. Tasks follow a state machine that transitions
  from :pending through :in_progress to :completed.

  ## Usage

  The task manager requires a shared Agent to maintain state across tool calls:

      alias Mojentic.LLM.Tools.EphemeralTaskManager
      alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

      # Create a shared task list agent
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)

      # Create tool instances that share the agent
      tools = [
        EphemeralTaskManager.AppendTask.new(agent),
        EphemeralTaskManager.PrependTask.new(agent),
        EphemeralTaskManager.InsertTaskAfter.new(agent),
        EphemeralTaskManager.StartTask.new(agent),
        EphemeralTaskManager.CompleteTask.new(agent),
        EphemeralTaskManager.ListTasks.new(agent),
        EphemeralTaskManager.ClearTasks.new(agent)
      ]

      # Use with broker
      {:ok, response} = Broker.generate(broker, messages, tools)

  ## Example

      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.Ollama
      alias Mojentic.LLM.Tools.EphemeralTaskManager
      alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

      # Setup
      broker = Broker.new("qwen3:32b", Ollama)
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)

      tools = [
        EphemeralTaskManager.AppendTask.new(agent),
        EphemeralTaskManager.StartTask.new(agent),
        EphemeralTaskManager.CompleteTask.new(agent),
        EphemeralTaskManager.ListTasks.new(agent)
      ]

      # Use the LLM with task management tools
      message = Message.user("Create 3 tasks: write tests, write docs, write code")
      {:ok, response} = Broker.generate(broker, [message], tools)

  """

  alias Mojentic.LLM.Tools.EphemeralTaskManager.TaskList

  # Module aliases for internal use
  alias Mojentic.LLM.Tools.EphemeralTaskManager.AppendTask
  alias Mojentic.LLM.Tools.EphemeralTaskManager.ClearTasks
  alias Mojentic.LLM.Tools.EphemeralTaskManager.CompleteTask
  alias Mojentic.LLM.Tools.EphemeralTaskManager.InsertTaskAfter
  alias Mojentic.LLM.Tools.EphemeralTaskManager.ListTasks
  alias Mojentic.LLM.Tools.EphemeralTaskManager.PrependTask
  alias Mojentic.LLM.Tools.EphemeralTaskManager.StartTask

  @doc """
  Creates all task manager tools with a shared agent.

  Returns a list of tool instances ready to be used with the broker.

  ## Examples

      alias Mojentic.LLM.Tools.EphemeralTaskManager

      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      tools = EphemeralTaskManager.all_tools(agent)

  """
  def all_tools(agent) do
    [
      AppendTask.new(agent),
      PrependTask.new(agent),
      InsertTaskAfter.new(agent),
      StartTask.new(agent),
      CompleteTask.new(agent),
      ListTasks.new(agent),
      ClearTasks.new(agent)
    ]
  end
end
