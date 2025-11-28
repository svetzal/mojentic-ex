defmodule Mojentic.Agents.SimpleRecursiveAgentTest do
  use ExUnit.Case, async: false

  alias Mojentic.Agents.SimpleRecursiveAgent

  alias Mojentic.Agents.SimpleRecursiveAgent.{
    EventEmitter,
    GoalState,
    GoalSubmittedEvent,
    IterationCompletedEvent,
    GoalAchievedEvent,
    GoalFailedEvent
  }

  alias Mojentic.LLM.{Broker, GatewayResponse, ToolCall}

  # Mock gateway for testing - using Agent for cross-process state
  defmodule MockGatewayState do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{response_fn: nil, call_count: 0} end, name: __MODULE__)
    end

    def set_response_fn(fun) do
      Agent.update(__MODULE__, fn state -> %{state | response_fn: fun} end)
    end

    def get_response_fn do
      Agent.get(__MODULE__, fn state -> state.response_fn end)
    end

    def increment_call_count do
      Agent.update(__MODULE__, fn state -> %{state | call_count: state.call_count + 1} end)
    end

    def get_call_count do
      Agent.get(__MODULE__, fn state -> state.call_count end)
    end

    def reset do
      Agent.update(__MODULE__, fn _state -> %{response_fn: nil, call_count: 0} end)
    end
  end

  defmodule MockGateway do
    @behaviour Mojentic.LLM.Gateway

    @impl true
    def complete(_model, messages, _tools, _config) do
      MockGatewayState.increment_call_count()

      case MockGatewayState.get_response_fn() do
        nil ->
          {:ok, %GatewayResponse{content: "Mock response", tool_calls: [], object: nil}}

        fun when is_function(fun) ->
          fun.(messages)
      end
    end

    @impl true
    def complete_object(_model, _messages, _schema, _config) do
      {:ok, %GatewayResponse{content: nil, tool_calls: [], object: %{"test" => "value"}}}
    end

    @impl true
    def get_available_models do
      {:ok, ["model1", "model2"]}
    end

    @impl true
    def calculate_embeddings(_model, _text) do
      {:ok, [0.1, 0.2, 0.3]}
    end

    @impl true
    def complete_stream(_model, _messages, _tools, _config) do
      Stream.map(["Mock ", "stream"], fn chunk -> {:content, chunk} end)
    end
  end

  # Mock tool for testing
  defmodule MockTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args) do
      case Map.get(args, "fail") do
        true -> {:error, {:tool_error, "Tool failed"}}
        _ -> {:ok, %{result: "tool executed", input: args}}
      end
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "mock_tool",
          description: "A mock tool for testing",
          parameters: %{
            type: "object",
            properties: %{
              value: %{type: "number", description: "A test value"}
            }
          }
        }
      }
    end

    def matches?(name), do: name == "mock_tool"
  end

  setup do
    # Always start a fresh supervised agent for each test
    # This ensures proper cleanup between tests and avoids race conditions
    start_supervised!(MockGatewayState)

    broker = Broker.new("test-model", MockGateway)

    {:ok, broker: broker}
  end

  describe "GoalState" do
    test "creates goal state with defaults" do
      state = %GoalState{goal: "test goal"}

      assert state.goal == "test goal"
      assert state.iteration == 0
      assert state.max_iterations == 5
      assert state.solution == nil
      assert state.is_complete == false
    end

    test "creates goal state with custom values" do
      state = %GoalState{
        goal: "custom goal",
        iteration: 2,
        max_iterations: 10,
        solution: "partial solution",
        is_complete: true
      }

      assert state.goal == "custom goal"
      assert state.iteration == 2
      assert state.max_iterations == 10
      assert state.solution == "partial solution"
      assert state.is_complete == true
    end
  end

  describe "EventEmitter" do
    test "starts successfully" do
      assert {:ok, pid} = EventEmitter.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "subscribes and emits events" do
      {:ok, emitter} = EventEmitter.start_link()
      test_pid = self()

      ref =
        EventEmitter.subscribe(emitter, GoalSubmittedEvent, fn event ->
          send(test_pid, {:event_received, event})
        end)

      assert is_reference(ref)

      state = %GoalState{goal: "test"}
      event = %GoalSubmittedEvent{state: state}
      EventEmitter.emit(emitter, event)

      # Wait for async task to complete
      assert_receive {:event_received, ^event}, 1000

      GenServer.stop(emitter)
    end

    test "unsubscribes from events" do
      {:ok, emitter} = EventEmitter.start_link()
      test_pid = self()

      ref =
        EventEmitter.subscribe(emitter, GoalSubmittedEvent, fn event ->
          send(test_pid, {:event_received, event})
        end)

      EventEmitter.unsubscribe(emitter, ref)

      state = %GoalState{goal: "test"}
      event = %GoalSubmittedEvent{state: state}
      EventEmitter.emit(emitter, event)

      # Should not receive event after unsubscribe
      refute_receive {:event_received, _}, 200

      GenServer.stop(emitter)
    end

    test "supports multiple subscribers for same event type" do
      {:ok, emitter} = EventEmitter.start_link()
      test_pid = self()

      EventEmitter.subscribe(emitter, GoalSubmittedEvent, fn _event ->
        send(test_pid, {:subscriber_1})
      end)

      EventEmitter.subscribe(emitter, GoalSubmittedEvent, fn _event ->
        send(test_pid, {:subscriber_2})
      end)

      state = %GoalState{goal: "test"}
      event = %GoalSubmittedEvent{state: state}
      EventEmitter.emit(emitter, event)

      assert_receive {:subscriber_1}, 1000
      assert_receive {:subscriber_2}, 1000

      GenServer.stop(emitter)
    end

    test "supports different event types" do
      {:ok, emitter} = EventEmitter.start_link()
      test_pid = self()

      EventEmitter.subscribe(emitter, GoalSubmittedEvent, fn _event ->
        send(test_pid, {:goal_submitted})
      end)

      EventEmitter.subscribe(emitter, GoalAchievedEvent, fn _event ->
        send(test_pid, {:goal_achieved})
      end)

      state = %GoalState{goal: "test"}

      EventEmitter.emit(emitter, %GoalSubmittedEvent{state: state})
      assert_receive {:goal_submitted}, 1000
      refute_receive {:goal_achieved}, 200

      EventEmitter.emit(emitter, %GoalAchievedEvent{state: state})
      assert_receive {:goal_achieved}, 1000

      GenServer.stop(emitter)
    end
  end

  describe "new/2" do
    test "creates agent with default options", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker)

      assert agent.broker == broker
      assert agent.tools == []
      assert agent.max_iterations == 5
      assert String.contains?(agent.system_prompt, "problem-solving")
      assert is_pid(agent.emitter)
      assert Process.alive?(agent.emitter)
    end

    test "creates agent with custom options", %{broker: broker} do
      agent =
        SimpleRecursiveAgent.new(broker,
          tools: [MockTool],
          max_iterations: 10,
          system_prompt: "Custom prompt"
        )

      assert agent.tools == [MockTool]
      assert agent.max_iterations == 10
      assert agent.system_prompt == "Custom prompt"
    end
  end

  describe "solve/2" do
    test "solves simple problem with DONE response", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 3)

      MockGatewayState.set_response_fn(fn _messages ->
        {:ok, %GatewayResponse{content: "The answer is 4. DONE", tool_calls: [], object: nil}}
      end)

      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "What is 2+2?")
      assert solution == "The answer is 4. DONE"
    end

    test "solves problem with FAIL response", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 3)

      MockGatewayState.set_response_fn(fn _messages ->
        {:ok,
         %GatewayResponse{
           content: "I cannot solve this problem. FAIL",
           tool_calls: [],
           object: nil
         }}
      end)

      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Impossible task")
      assert String.contains?(solution, "Failed to solve")
      assert String.contains?(solution, "cannot solve")
    end

    test "reaches max iterations without completion", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 2)

      MockGatewayState.set_response_fn(fn _messages ->
        {:ok, %GatewayResponse{content: "Working on it...", tool_calls: [], object: nil}}
      end)

      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Complex problem")
      assert String.contains?(solution, "Best solution after 2 iterations")
      assert String.contains?(solution, "Working on it")

      # Should have called exactly max_iterations times
      assert MockGatewayState.get_call_count() == 2
    end

    test "handles multiple iterations before DONE", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 5)

      # Track iteration within the response function using a mutable counter
      iteration_count = :counters.new(1, [:atomics])

      MockGatewayState.set_response_fn(fn _messages ->
        # Increment and get the current iteration
        :counters.add(iteration_count, 1, 1)
        count = :counters.get(iteration_count, 1)

        content =
          case count do
            1 -> "Still working on it, iteration 1..."
            2 -> "Still working on it, iteration 2..."
            3 -> "Found the answer! DONE"
            _ -> "Should not get here"
          end

        {:ok, %GatewayResponse{content: content, tool_calls: [], object: nil}}
      end)

      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Multi-step problem")
      assert solution == "Found the answer! DONE"

      # Should have called 3 times before completing
      assert MockGatewayState.get_call_count() == 3
    end

    test "handles broker errors gracefully", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 3)

      MockGatewayState.set_response_fn(fn _messages ->
        {:error, {:http_error, 500}}
      end)

      # The error should be caught and wrapped in a failed event
      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Error test")
      assert String.contains?(solution, "Error:")
    end

    test "case-insensitive DONE detection", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker)

      test_cases = [
        "Task complete - done",
        "We are DONE here",
        "Done with the task",
        "I'm done"
      ]

      for content <- test_cases do
        MockGatewayState.reset()

        MockGatewayState.set_response_fn(fn _messages ->
          {:ok, %GatewayResponse{content: content, tool_calls: [], object: nil}}
        end)

        assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Test")
        assert solution == content
      end
    end

    test "case-insensitive FAIL detection", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker)

      test_cases = [
        "This will fail",
        "Task FAIL",
        "I must Fail this",
        "fail to complete"
      ]

      for content <- test_cases do
        MockGatewayState.reset()

        MockGatewayState.set_response_fn(fn _messages ->
          {:ok, %GatewayResponse{content: content, tool_calls: [], object: nil}}
        end)

        assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Test")
        assert String.contains?(solution, "Failed to solve")
        assert String.contains?(solution, content)
      end
    end

    test "does not trigger false positives for DONE/FAIL", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 1)

      # These should NOT trigger completion
      # Note: "abandoned", "failed", "unfailing" contain the words but in compound forms
      # "not yet done" still contains "done" as a word, so it WILL match
      test_cases = [
        "I have abandoned this approach",
        "The system failed earlier",
        "This is unfailing logic"
      ]

      for content <- test_cases do
        MockGatewayState.reset()

        MockGatewayState.set_response_fn(fn _messages ->
          {:ok, %GatewayResponse{content: content, tool_calls: [], object: nil}}
        end)

        assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Test")
        # Should reach max iterations, not trigger early completion
        assert String.contains?(solution, "Best solution after 1 iterations")
      end
    end

    test "passes tools to chat session", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, tools: [MockTool])

      MockGatewayState.set_response_fn(fn messages ->
        # First call: request tool
        # Second call: complete with result
        if length(messages) == 2 do
          {:ok,
           %GatewayResponse{
             content: "",
             tool_calls: [
               %ToolCall{
                 id: "call-1",
                 name: "mock_tool",
                 arguments: %{"value" => 42}
               }
             ],
             object: nil
           }}
        else
          {:ok,
           %GatewayResponse{content: "Tool result processed. DONE", tool_calls: [], object: nil}}
        end
      end)

      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Use the tool")
      assert solution == "Tool result processed. DONE"
    end

    test "uses custom system prompt", %{broker: broker} do
      custom_prompt = "You are a specialized math assistant."
      agent = SimpleRecursiveAgent.new(broker, system_prompt: custom_prompt)

      MockGatewayState.set_response_fn(fn messages ->
        # Verify system message uses custom prompt
        system_msg = Enum.find(messages, fn msg -> msg.role == :system end)

        if system_msg && system_msg.content == custom_prompt do
          {:ok, %GatewayResponse{content: "Correct prompt. DONE", tool_calls: [], object: nil}}
        else
          {:ok, %GatewayResponse{content: "Wrong prompt. FAIL", tool_calls: [], object: nil}}
        end
      end)

      assert {:ok, solution} = SimpleRecursiveAgent.solve(agent, "Test")
      assert solution == "Correct prompt. DONE"
    end
  end

  describe "event flow" do
    test "emits events in correct order for successful completion", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker, max_iterations: 3)
      test_pid = self()

      # Subscribe to all events
      EventEmitter.subscribe(agent.emitter, GoalSubmittedEvent, fn event ->
        send(test_pid, {:event, :goal_submitted, event.state.iteration})
      end)

      EventEmitter.subscribe(agent.emitter, IterationCompletedEvent, fn event ->
        send(test_pid, {:event, :iteration_completed, event.state.iteration, event.response})
      end)

      EventEmitter.subscribe(agent.emitter, GoalAchievedEvent, fn event ->
        send(test_pid, {:event, :goal_achieved, event.state.iteration})
      end)

      MockGatewayState.set_response_fn(fn _messages ->
        {:ok, %GatewayResponse{content: "Success! DONE", tool_calls: [], object: nil}}
      end)

      Task.async(fn ->
        SimpleRecursiveAgent.solve(agent, "Test problem")
      end)

      # Verify event order
      assert_receive {:event, :goal_submitted, 0}, 1000
      assert_receive {:event, :iteration_completed, 1, "Success! DONE"}, 1000
      assert_receive {:event, :goal_achieved, 1}, 1000
    end

    test "emits events for failure", %{broker: broker} do
      agent = SimpleRecursiveAgent.new(broker)
      test_pid = self()

      EventEmitter.subscribe(agent.emitter, GoalFailedEvent, fn event ->
        send(test_pid, {:event, :goal_failed, event.state.solution})
      end)

      MockGatewayState.set_response_fn(fn _messages ->
        {:ok, %GatewayResponse{content: "Cannot do this. FAIL", tool_calls: [], object: nil}}
      end)

      Task.async(fn ->
        SimpleRecursiveAgent.solve(agent, "Impossible")
      end)

      assert_receive {:event, :goal_failed, solution}, 1000
      assert String.contains?(solution, "Failed to solve")
    end
  end
end
