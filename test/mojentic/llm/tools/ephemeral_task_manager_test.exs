defmodule Mojentic.LLM.Tools.EphemeralTaskManagerTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.EphemeralTaskManager

  alias Mojentic.LLM.Tools.EphemeralTaskManager.{
    AppendTask,
    ClearTasks,
    CompleteTask,
    InsertTaskAfter,
    ListTasks,
    PrependTask,
    StartTask,
    Task,
    TaskList
  }

  describe "Task" do
    test "creates a new task with pending status" do
      task = Task.new(1, "Write tests")

      assert task.id == 1
      assert task.description == "Write tests"
      assert task.status == :pending
    end

    test "status_to_string converts status atoms to strings" do
      assert Task.status_to_string(:pending) == "pending"
      assert Task.status_to_string(:in_progress) == "in_progress"
      assert Task.status_to_string(:completed) == "completed"
    end
  end

  describe "TaskList" do
    test "new creates an empty task list" do
      task_list = TaskList.new()

      assert task_list.tasks == []
      assert task_list.next_id == 1
    end

    test "append_task adds task to end of list" do
      task_list = TaskList.new()

      {task1, task_list} = TaskList.append_task(task_list, "Task 1")
      {task2, task_list} = TaskList.append_task(task_list, "Task 2")

      assert task1.id == 1
      assert task1.description == "Task 1"
      assert task1.status == :pending

      assert task2.id == 2
      assert task2.description == "Task 2"

      assert length(task_list.tasks) == 2
      assert task_list.next_id == 3
      assert List.last(task_list.tasks).id == 2
    end

    test "prepend_task adds task to beginning of list" do
      task_list = TaskList.new()

      {task1, task_list} = TaskList.append_task(task_list, "Task 1")
      {task2, task_list} = TaskList.prepend_task(task_list, "Task 2")

      assert task2.id == 2
      assert List.first(task_list.tasks).id == 2
      assert List.last(task_list.tasks).id == 1
    end

    test "insert_task_after inserts task at correct position" do
      task_list = TaskList.new()

      {task1, task_list} = TaskList.append_task(task_list, "Task 1")
      {_task2, task_list} = TaskList.append_task(task_list, "Task 2")
      {:ok, task3, task_list} = TaskList.insert_task_after(task_list, task1.id, "Task 3")

      assert task3.id == 3
      assert task3.description == "Task 3"

      task_ids = Enum.map(task_list.tasks, & &1.id)
      assert task_ids == [1, 3, 2]
    end

    test "insert_task_after returns error for nonexistent task" do
      task_list = TaskList.new()
      {_task, task_list} = TaskList.append_task(task_list, "Task 1")

      assert {:error, reason} = TaskList.insert_task_after(task_list, 999, "New Task")
      assert reason =~ "No task with ID '999'"
    end

    test "start_task changes status from pending to in_progress" do
      task_list = TaskList.new()
      {task, task_list} = TaskList.append_task(task_list, "Task 1")

      assert task.status == :pending
      {:ok, started_task, task_list} = TaskList.start_task(task_list, task.id)

      assert started_task.status == :in_progress
      assert started_task.id == task.id

      # Verify it's updated in the list
      updated_task = Enum.find(task_list.tasks, &(&1.id == task.id))
      assert updated_task.status == :in_progress
    end

    test "start_task returns error for nonexistent task" do
      task_list = TaskList.new()

      assert {:error, reason} = TaskList.start_task(task_list, 999)
      assert reason =~ "No task with ID '999'"
    end

    test "start_task returns error if task is not pending" do
      task_list = TaskList.new()
      {task, task_list} = TaskList.append_task(task_list, "Task 1")
      {:ok, _started, task_list} = TaskList.start_task(task_list, task.id)

      assert {:error, reason} = TaskList.start_task(task_list, task.id)
      assert reason =~ "cannot be started because it is not in PENDING status"
    end

    test "complete_task changes status from in_progress to completed" do
      task_list = TaskList.new()
      {task, task_list} = TaskList.append_task(task_list, "Task 1")
      {:ok, _started, task_list} = TaskList.start_task(task_list, task.id)

      {:ok, completed_task, task_list} = TaskList.complete_task(task_list, task.id)

      assert completed_task.status == :completed
      assert completed_task.id == task.id

      # Verify it's updated in the list
      updated_task = Enum.find(task_list.tasks, &(&1.id == task.id))
      assert updated_task.status == :completed
    end

    test "complete_task returns error for nonexistent task" do
      task_list = TaskList.new()

      assert {:error, reason} = TaskList.complete_task(task_list, 999)
      assert reason =~ "No task with ID '999'"
    end

    test "complete_task returns error if task is not in_progress" do
      task_list = TaskList.new()
      {task, task_list} = TaskList.append_task(task_list, "Task 1")

      assert {:error, reason} = TaskList.complete_task(task_list, task.id)
      assert reason =~ "cannot be completed because it is not in IN_PROGRESS status"
    end

    test "list_tasks returns all tasks" do
      task_list = TaskList.new()
      {_task1, task_list} = TaskList.append_task(task_list, "Task 1")
      {_task2, task_list} = TaskList.append_task(task_list, "Task 2")

      tasks = TaskList.list_tasks(task_list)

      assert length(tasks) == 2
      assert Enum.map(tasks, & &1.description) == ["Task 1", "Task 2"]
    end

    test "clear_tasks removes all tasks and returns count" do
      task_list = TaskList.new()
      {_task1, task_list} = TaskList.append_task(task_list, "Task 1")
      {_task2, task_list} = TaskList.append_task(task_list, "Task 2")

      {count, empty_list} = TaskList.clear_tasks(task_list)

      assert count == 2
      assert empty_list.tasks == []
      # next_id should be preserved
      assert empty_list.next_id == 3
    end
  end

  describe "AppendTask tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      %{agent: agent, tool: AppendTask.new(agent)}
    end

    test "has correct descriptor" do
      descriptor = AppendTask.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "append_task"
      assert descriptor[:function][:description] =~ "Append a new task"
      assert descriptor[:function][:parameters][:required] == ["description"]
    end

    test "appends task successfully", %{tool: tool, agent: agent} do
      assert {:ok, result} = AppendTask.run(tool, %{"description" => "My task"})

      assert result[:id] == 1
      assert result[:description] == "My task"
      assert result[:status] == "pending"
      assert result[:summary] =~ "appended successfully"

      # Verify agent state
      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      assert length(tasks) == 1
      assert hd(tasks).description == "My task"
    end

    test "handles empty description", %{tool: tool} do
      assert {:ok, result} = AppendTask.run(tool, %{})
      assert result[:description] == ""
    end

    test "multiple appends maintain order", %{tool: tool, agent: agent} do
      AppendTask.run(tool, %{"description" => "Task 1"})
      AppendTask.run(tool, %{"description" => "Task 2"})
      AppendTask.run(tool, %{"description" => "Task 3"})

      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      assert length(tasks) == 3
      assert Enum.map(tasks, & &1.description) == ["Task 1", "Task 2", "Task 3"]
    end
  end

  describe "PrependTask tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      %{agent: agent, tool: PrependTask.new(agent)}
    end

    test "has correct descriptor" do
      descriptor = PrependTask.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "prepend_task"
      assert descriptor[:function][:description] =~ "Prepend a new task"
    end

    test "prepends task to beginning", %{tool: tool, agent: agent} do
      append_tool = AppendTask.new(agent)
      AppendTask.run(append_tool, %{"description" => "Task 1"})

      assert {:ok, result} = PrependTask.run(tool, %{"description" => "Task 0"})

      assert result[:id] == 2
      assert result[:description] == "Task 0"
      assert result[:summary] =~ "prepended successfully"

      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      assert Enum.map(tasks, & &1.description) == ["Task 0", "Task 1"]
    end
  end

  describe "InsertTaskAfter tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      append_tool = AppendTask.new(agent)
      {:ok, task1} = AppendTask.run(append_tool, %{"description" => "Task 1"})
      {:ok, _task2} = AppendTask.run(append_tool, %{"description" => "Task 2"})

      %{agent: agent, tool: InsertTaskAfter.new(agent), task1_id: task1[:id]}
    end

    test "has correct descriptor" do
      descriptor = InsertTaskAfter.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "insert_task_after"
      assert descriptor[:function][:parameters][:required] == ["existing_task_id", "description"]
    end

    test "inserts task after existing task", %{tool: tool, agent: agent, task1_id: task1_id} do
      assert {:ok, result} =
               InsertTaskAfter.run(tool, %{
                 "existing_task_id" => task1_id,
                 "description" => "Task 1.5"
               })

      assert result[:description] == "Task 1.5"
      assert result[:summary] =~ "inserted after"

      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      assert Enum.map(tasks, & &1.description) == ["Task 1", "Task 1.5", "Task 2"]
    end

    test "handles string task_id", %{tool: tool, task1_id: task1_id} do
      assert {:ok, _result} =
               InsertTaskAfter.run(tool, %{
                 "existing_task_id" => "#{task1_id}",
                 "description" => "Task X"
               })
    end

    test "returns error for nonexistent task", %{tool: tool} do
      assert {:error, result} =
               InsertTaskAfter.run(tool, %{
                 "existing_task_id" => 999,
                 "description" => "Task X"
               })

      assert result[:error] =~ "No task with ID '999'"
      assert result[:summary] =~ "Failed to insert"
    end
  end

  describe "StartTask tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      append_tool = AppendTask.new(agent)
      {:ok, task} = AppendTask.run(append_tool, %{"description" => "Task 1"})

      %{agent: agent, tool: StartTask.new(agent), task_id: task[:id]}
    end

    test "has correct descriptor" do
      descriptor = StartTask.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "start_task"
      assert descriptor[:function][:parameters][:required] == ["id"]
    end

    test "starts a pending task", %{tool: tool, agent: agent, task_id: task_id} do
      assert {:ok, result} = StartTask.run(tool, %{"id" => task_id})

      assert result[:status] == "in_progress"
      assert result[:summary] =~ "started successfully"

      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      task = Enum.find(tasks, &(&1.id == task_id))
      assert task.status == :in_progress
    end

    test "handles string task_id", %{tool: tool, task_id: task_id} do
      assert {:ok, _result} = StartTask.run(tool, %{"id" => "#{task_id}"})
    end

    test "returns error for nonexistent task", %{tool: tool} do
      assert {:error, result} = StartTask.run(tool, %{"id" => 999})

      assert result[:error] =~ "No task with ID '999'"
      assert result[:summary] =~ "Failed to start"
    end

    test "returns error when task is not pending", %{tool: tool, task_id: task_id} do
      StartTask.run(tool, %{"id" => task_id})

      assert {:error, result} = StartTask.run(tool, %{"id" => task_id})
      assert result[:error] =~ "not in PENDING status"
    end
  end

  describe "CompleteTask tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      append_tool = AppendTask.new(agent)
      {:ok, task} = AppendTask.run(append_tool, %{"description" => "Task 1"})
      start_tool = StartTask.new(agent)
      StartTask.run(start_tool, %{"id" => task[:id]})

      %{agent: agent, tool: CompleteTask.new(agent), task_id: task[:id]}
    end

    test "has correct descriptor" do
      descriptor = CompleteTask.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "complete_task"
      assert descriptor[:function][:parameters][:required] == ["id"]
    end

    test "completes an in_progress task", %{tool: tool, agent: agent, task_id: task_id} do
      assert {:ok, result} = CompleteTask.run(tool, %{"id" => task_id})

      assert result[:status] == "completed"
      assert result[:summary] =~ "completed successfully"

      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      task = Enum.find(tasks, &(&1.id == task_id))
      assert task.status == :completed
    end

    test "handles string task_id", %{tool: tool, task_id: task_id} do
      assert {:ok, _result} = CompleteTask.run(tool, %{"id" => "#{task_id}"})
    end

    test "returns error for nonexistent task", %{tool: tool} do
      assert {:error, result} = CompleteTask.run(tool, %{"id" => 999})

      assert result[:error] =~ "No task with ID '999'"
      assert result[:summary] =~ "Failed to complete"
    end

    test "returns error when task is not in_progress" do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      append_tool = AppendTask.new(agent)
      {:ok, task} = AppendTask.run(append_tool, %{"description" => "Task 1"})
      tool = CompleteTask.new(agent)

      assert {:error, result} = CompleteTask.run(tool, %{"id" => task[:id]})
      assert result[:error] =~ "not in IN_PROGRESS status"
    end
  end

  describe "ListTasks tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      %{agent: agent, tool: ListTasks.new(agent)}
    end

    test "has correct descriptor" do
      descriptor = ListTasks.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "list_tasks"
    end

    test "lists empty task list", %{tool: tool} do
      assert {:ok, result} = ListTasks.run(tool, %{})

      assert result[:count] == 0
      assert result[:tasks] == "No tasks found."
      assert result[:summary] =~ "Found 0 tasks"
    end

    test "lists all tasks with formatting", %{tool: tool, agent: agent} do
      append_tool = AppendTask.new(agent)
      start_tool = StartTask.new(agent)

      {:ok, task1} = AppendTask.run(append_tool, %{"description" => "Task 1"})
      {:ok, _task2} = AppendTask.run(append_tool, %{"description" => "Task 2"})
      StartTask.run(start_tool, %{"id" => task1[:id]})

      assert {:ok, result} = ListTasks.run(tool, %{})

      assert result[:count] == 2
      assert result[:tasks] =~ "1. Task 1 (in_progress)"
      assert result[:tasks] =~ "2. Task 2 (pending)"
      assert result[:summary] =~ "Found 2 tasks"
    end
  end

  describe "ClearTasks tool" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      %{agent: agent, tool: ClearTasks.new(agent)}
    end

    test "has correct descriptor" do
      descriptor = ClearTasks.descriptor()

      assert descriptor[:type] == "function"
      assert descriptor[:function][:name] == "clear_tasks"
    end

    test "clears all tasks", %{tool: tool, agent: agent} do
      append_tool = AppendTask.new(agent)
      AppendTask.run(append_tool, %{"description" => "Task 1"})
      AppendTask.run(append_tool, %{"description" => "Task 2"})
      AppendTask.run(append_tool, %{"description" => "Task 3"})

      assert {:ok, result} = ClearTasks.run(tool, %{})

      assert result[:count] == 3
      assert result[:summary] =~ "Cleared 3 tasks"

      tasks = Agent.get(agent, &TaskList.list_tasks/1)
      assert tasks == []
    end

    test "clears empty list", %{tool: tool} do
      assert {:ok, result} = ClearTasks.run(tool, %{})
      assert result[:count] == 0
    end
  end

  describe "EphemeralTaskManager.all_tools/1" do
    test "returns all task manager tools" do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)
      tools = EphemeralTaskManager.all_tools(agent)

      assert length(tools) == 7

      tool_structs = Enum.map(tools, & &1.__struct__)
      assert AppendTask in tool_structs
      assert PrependTask in tool_structs
      assert InsertTaskAfter in tool_structs
      assert StartTask in tool_structs
      assert CompleteTask in tool_structs
      assert ListTasks in tool_structs
      assert ClearTasks in tool_structs

      # Verify all tools share the same agent
      assert Enum.all?(tools, fn tool -> tool.agent == agent end)
    end
  end

  describe "integration workflow" do
    test "complete task lifecycle" do
      {:ok, agent} = Agent.start_link(fn -> TaskList.new() end)

      append_tool = AppendTask.new(agent)
      prepend_tool = PrependTask.new(agent)
      insert_tool = InsertTaskAfter.new(agent)
      start_tool = StartTask.new(agent)
      complete_tool = CompleteTask.new(agent)
      list_tool = ListTasks.new(agent)
      clear_tool = ClearTasks.new(agent)

      # Create tasks
      {:ok, task1} = AppendTask.run(append_tool, %{"description" => "Write code"})
      {:ok, task3} = AppendTask.run(append_tool, %{"description" => "Deploy"})

      {:ok, _task2} =
        InsertTaskAfter.run(insert_tool, %{
          "existing_task_id" => task1[:id],
          "description" => "Write tests"
        })

      {:ok, _task0} = PrependTask.run(prepend_tool, %{"description" => "Design"})

      # List tasks
      {:ok, list_result} = ListTasks.run(list_tool, %{})
      assert list_result[:count] == 4
      assert list_result[:tasks] =~ "Design"
      assert list_result[:tasks] =~ "Write code"
      assert list_result[:tasks] =~ "Write tests"
      assert list_result[:tasks] =~ "Deploy"

      # Start and complete a task
      {:ok, _started} = StartTask.run(start_tool, %{"id" => task1[:id]})
      {:ok, completed} = CompleteTask.run(complete_tool, %{"id" => task1[:id]})
      assert completed[:status] == "completed"

      # Clear all tasks
      {:ok, clear_result} = ClearTasks.run(clear_tool, %{})
      assert clear_result[:count] == 4

      # Verify empty
      {:ok, final_list} = ListTasks.run(list_tool, %{})
      assert final_list[:count] == 0
    end
  end
end
