defmodule Mojentic.LLM.Tools.EphemeralTaskManager.TaskList do
  @moduledoc """
  Manages a list of tasks for the ephemeral task manager.

  This module provides functions for adding, starting, completing, and listing tasks.
  Tasks follow a state machine that transitions from :pending through :in_progress to :completed.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {task, task_list} = TaskList.append_task(task_list, "Write tests")
      iex> task.description
      "Write tests"

  """

  alias Mojentic.LLM.Tools.EphemeralTaskManager.Task

  @type t :: %__MODULE__{
          tasks: [Task.t()],
          next_id: pos_integer()
        }

  defstruct tasks: [], next_id: 1

  @doc """
  Creates a new empty task list.

  ## Examples

      iex> TaskList.new()
      %TaskList{tasks: [], next_id: 1}

  """
  def new do
    %__MODULE__{}
  end

  @doc """
  Appends a new task to the end of the list.

  Returns a tuple of the created task and the updated task list.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {task, task_list} = TaskList.append_task(task_list, "Write tests")
      iex> task.status
      :pending

  """
  def append_task(%__MODULE__{tasks: tasks, next_id: next_id} = _list, description) do
    task = Task.new(next_id, description)
    updated_list = %__MODULE__{tasks: tasks ++ [task], next_id: next_id + 1}
    {task, updated_list}
  end

  @doc """
  Prepends a new task to the beginning of the list.

  Returns a tuple of the created task and the updated task list.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {task, task_list} = TaskList.prepend_task(task_list, "Important task")
      iex> task.status
      :pending

  """
  def prepend_task(%__MODULE__{tasks: tasks, next_id: next_id} = _list, description) do
    task = Task.new(next_id, description)
    updated_list = %__MODULE__{tasks: [task | tasks], next_id: next_id + 1}
    {task, updated_list}
  end

  @doc """
  Inserts a new task after an existing task with the given ID.

  Returns `{:ok, task, updated_list}` on success or `{:error, reason}` if the
  existing task is not found.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {_task1, task_list} = TaskList.append_task(task_list, "Task 1")
      iex> {:ok, task2, task_list} = TaskList.insert_task_after(task_list, 1, "Task 2")
      iex> task2.description
      "Task 2"

  """
  def insert_task_after(%__MODULE__{tasks: tasks, next_id: next_id} = _list, existing_task_id, description) do
    case find_task_index(tasks, existing_task_id) do
      nil ->
        {:error, "No task with ID '#{existing_task_id}' exists"}

      index ->
        task = Task.new(next_id, description)
        {before, after_} = Enum.split(tasks, index + 1)
        updated_tasks = before ++ [task | after_]
        updated_list = %__MODULE__{tasks: updated_tasks, next_id: next_id + 1}
        {:ok, task, updated_list}
    end
  end

  @doc """
  Starts a task by changing its status from :pending to :in_progress.

  Returns `{:ok, task, updated_list}` on success or `{:error, reason}` if the
  task is not found or not in :pending status.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {task, task_list} = TaskList.append_task(task_list, "Task 1")
      iex> {:ok, started_task, task_list} = TaskList.start_task(task_list, task.id)
      iex> started_task.status
      :in_progress

  """
  def start_task(%__MODULE__{tasks: tasks} = list, task_id) do
    case find_task(tasks, task_id) do
      nil ->
        {:error, "No task with ID '#{task_id}' exists"}

      task ->
        if task.status != :pending do
          {:error, "Task '#{task_id}' cannot be started because it is not in PENDING status"}
        else
          updated_task = %{task | status: :in_progress}
          updated_tasks = update_task_in_list(tasks, updated_task)
          updated_list = %{list | tasks: updated_tasks}
          {:ok, updated_task, updated_list}
        end
    end
  end

  @doc """
  Completes a task by changing its status from :in_progress to :completed.

  Returns `{:ok, task, updated_list}` on success or `{:error, reason}` if the
  task is not found or not in :in_progress status.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {task, task_list} = TaskList.append_task(task_list, "Task 1")
      iex> {:ok, _, task_list} = TaskList.start_task(task_list, task.id)
      iex> {:ok, completed_task, task_list} = TaskList.complete_task(task_list, task.id)
      iex> completed_task.status
      :completed

  """
  def complete_task(%__MODULE__{tasks: tasks} = list, task_id) do
    case find_task(tasks, task_id) do
      nil ->
        {:error, "No task with ID '#{task_id}' exists"}

      task ->
        if task.status != :in_progress do
          {:error, "Task '#{task_id}' cannot be completed because it is not in IN_PROGRESS status"}
        else
          updated_task = %{task | status: :completed}
          updated_tasks = update_task_in_list(tasks, updated_task)
          updated_list = %{list | tasks: updated_tasks}
          {:ok, updated_task, updated_list}
        end
    end
  end

  @doc """
  Returns all tasks in the list.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {_task, task_list} = TaskList.append_task(task_list, "Task 1")
      iex> tasks = TaskList.list_tasks(task_list)
      iex> length(tasks)
      1

  """
  def list_tasks(%__MODULE__{tasks: tasks}) do
    tasks
  end

  @doc """
  Clears all tasks from the list.

  Returns a tuple of the count of cleared tasks and the empty task list.

  ## Examples

      iex> task_list = TaskList.new()
      iex> {_task, task_list} = TaskList.append_task(task_list, "Task 1")
      iex> {count, empty_list} = TaskList.clear_tasks(task_list)
      iex> count
      1
      iex> TaskList.list_tasks(empty_list)
      []

  """
  def clear_tasks(%__MODULE__{tasks: tasks, next_id: next_id}) do
    count = length(tasks)
    {count, %__MODULE__{tasks: [], next_id: next_id}}
  end

  # Private helpers

  defp find_task(tasks, task_id) do
    Enum.find(tasks, fn task -> task.id == task_id end)
  end

  defp find_task_index(tasks, task_id) do
    Enum.find_index(tasks, fn task -> task.id == task_id end)
  end

  defp update_task_in_list(tasks, updated_task) do
    Enum.map(tasks, fn task ->
      if task.id == updated_task.id, do: updated_task, else: task
    end)
  end
end
