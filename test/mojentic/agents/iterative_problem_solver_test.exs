defmodule Mojentic.Agents.IterativeProblemSolverTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.IterativeProblemSolver
  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.ToolCall

  # Mock gateway for testing
  defmodule MockGateway do
    @behaviour Mojentic.LLM.Gateway

    @impl true
    def complete(_model, messages, _tools, _config) do
      # Get the response generator function from process dictionary
      case Process.get(:mock_response_generator) do
        nil ->
          {:ok, %GatewayResponse{content: "Mock response", tool_calls: [], object: nil}}

        generator when is_function(generator, 1) ->
          generator.(messages)

        response ->
          {:ok, response}
      end
    end

    @impl true
    def complete_object(_model, _messages, _schema, _config) do
      {:ok, %GatewayResponse{content: nil, tool_calls: [], object: %{"test" => "value"}}}
    end

    @impl true
    def get_available_models do
      {:ok, ["test-model"]}
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
      case Map.get(args, "action") do
        "fail" -> {:error, {:tool_error, "Tool failed"}}
        action -> {:ok, %{result: "tool executed: #{action}", input: args}}
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
              action: %{type: "string", description: "Action to perform"}
            }
          }
        }
      }
    end
  end

  setup do
    # Clear process dictionary before each test
    Process.delete(:mock_response_generator)
    Process.delete(:call_count)

    broker = Broker.new("test-model", MockGateway)

    {:ok, broker: broker}
  end

  describe "new/2" do
    test "creates solver with default options", %{broker: broker} do
      solver = IterativeProblemSolver.new(broker)

      assert solver.broker == broker
      assert solver.tools == []
      assert solver.max_iterations == 3
      assert is_binary(solver.system_prompt)
      assert String.length(solver.system_prompt) > 0
      assert solver.temperature == 1.0
    end

    test "creates solver with custom options", %{broker: broker} do
      custom_prompt = "You are a specialized assistant."

      solver =
        IterativeProblemSolver.new(broker,
          tools: [MockTool],
          max_iterations: 5,
          system_prompt: custom_prompt,
          temperature: 0.7
        )

      assert solver.tools == [MockTool]
      assert solver.max_iterations == 5
      assert solver.system_prompt == custom_prompt
      assert solver.temperature == 0.7
    end

    test "accepts empty tools list", %{broker: broker} do
      solver = IterativeProblemSolver.new(broker, tools: [])
      assert solver.tools == []
    end
  end

  describe "solve/2 - successful completion" do
    test "completes on first iteration when DONE is returned", %{broker: broker} do
      # Mock: first step returns DONE, then summary request returns final result
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        # Skip system message
        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 ->
            # First user message (the problem step)
            {:ok, %GatewayResponse{content: "I solved it. DONE", tool_calls: [], object: nil}}

          2 ->
            # Second user message (summary request)
            {:ok,
             %GatewayResponse{
               content: "The answer is 42.",
               tool_calls: [],
               object: nil
             }}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected call", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 3)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Test problem")
      assert result == "The answer is 42."

      # Should have made exactly 2 LLM calls
      assert Process.get(:call_count) == 2
    end

    test "completes when DONE appears in response (case insensitive)", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 ->
            {:ok, %GatewayResponse{content: "Task is done!", tool_calls: [], object: nil}}

          2 ->
            {:ok, %GatewayResponse{content: "Final summary", tool_calls: [], object: nil}}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Test")
      assert result == "Final summary"
    end

    test "iterates multiple times before completion", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 -> {:ok, %GatewayResponse{content: "Working on it...", tool_calls: [], object: nil}}
          2 -> {:ok, %GatewayResponse{content: "Still working...", tool_calls: [], object: nil}}
          3 -> {:ok, %GatewayResponse{content: "DONE! Finished.", tool_calls: [], object: nil}}
          4 -> {:ok, %GatewayResponse{content: "Here's the result", tool_calls: [], object: nil}}
          _ -> {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 5)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Complex problem")
      assert result == "Here's the result"

      # 3 iteration steps + 1 summary = 4 calls
      assert Process.get(:call_count) == 4
    end
  end

  describe "solve/2 - explicit failure" do
    test "stops when FAIL is returned", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 ->
            {:ok,
             %GatewayResponse{content: "I cannot do this. FAIL", tool_calls: [], object: nil}}

          2 ->
            {:ok, %GatewayResponse{content: "Unable to complete", tool_calls: [], object: nil}}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 3)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Impossible task")
      assert result == "Unable to complete"

      # 1 iteration + 1 summary = 2 calls
      assert Process.get(:call_count) == 2
    end

    test "detects FAIL case insensitively", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 ->
            {:ok, %GatewayResponse{content: "I will fail at this.", tool_calls: [], object: nil}}

          2 ->
            {:ok, %GatewayResponse{content: "Failure summary", tool_calls: [], object: nil}}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Task")
      assert result == "Failure summary"
    end
  end

  describe "solve/2 - max iterations" do
    test "stops after max_iterations reached", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          n when n <= 3 ->
            {:ok, %GatewayResponse{content: "Iteration #{n}", tool_calls: [], object: nil}}

          4 ->
            {:ok, %GatewayResponse{content: "Max reached summary", tool_calls: [], object: nil}}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 3)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Never ending task")
      assert result == "Max reached summary"

      # 3 iterations + 1 summary = 4 calls
      assert Process.get(:call_count) == 4
    end

    test "respects custom max_iterations value", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        if length(user_messages) <= 5 do
          {:ok, %GatewayResponse{content: "Working", tool_calls: [], object: nil}}
        else
          {:ok, %GatewayResponse{content: "Summary", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 5)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Long task")
      assert result == "Summary"

      # 5 iterations + 1 summary = 6 calls
      assert Process.get(:call_count) == 6
    end

    test "handles max_iterations of 1", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 -> {:ok, %GatewayResponse{content: "Single attempt", tool_calls: [], object: nil}}
          2 -> {:ok, %GatewayResponse{content: "Summary after one", tool_calls: [], object: nil}}
          _ -> {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 1)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Quick task")
      assert result == "Summary after one"

      assert Process.get(:call_count) == 2
    end
  end

  describe "solve/2 - with tools" do
    test "passes tools to chat session", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)
        # Also check for tool messages to know when we're after tool execution
        tool_messages = Enum.filter(messages, fn msg -> msg.role == :tool end)

        cond do
          length(user_messages) == 1 and Enum.empty?(tool_messages) ->
            # First call: Return a tool call
            {:ok,
             %GatewayResponse{
               content: "",
               tool_calls: [
                 %ToolCall{
                   id: "call-1",
                   name: "mock_tool",
                   arguments: %{"action" => "test"}
                 }
               ],
               object: nil
             }}

          not Enum.empty?(tool_messages) ->
            # After tool execution: return DONE
            {:ok, %GatewayResponse{content: "Used tool. DONE", tool_calls: [], object: nil}}

          length(user_messages) == 2 ->
            # Summary request
            {:ok, %GatewayResponse{content: "Tool result summary", tool_calls: [], object: nil}}

          true ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, tools: [MockTool])

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Use a tool")
      assert result == "Tool result summary"
    end
  end

  describe "solve/2 - error handling" do
    test "propagates broker errors", %{broker: broker} do
      Process.put(:mock_response_generator, fn _messages ->
        {:error, {:http_error, 500}}
      end)

      solver = IterativeProblemSolver.new(broker)

      assert {:error, {:http_error, 500}} = IterativeProblemSolver.solve(solver, "Error test")
    end

    test "handles empty responses gracefully", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 -> {:ok, %GatewayResponse{content: "", tool_calls: [], object: nil}}
          2 -> {:ok, %GatewayResponse{content: "done", tool_calls: [], object: nil}}
          3 -> {:ok, %GatewayResponse{content: "Empty summary", tool_calls: [], object: nil}}
          _ -> {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 2)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Task")
      assert result == "Empty summary"
    end
  end

  describe "solve/2 - system prompt and temperature" do
    test "uses custom system prompt", %{broker: broker} do
      custom_prompt = "You are a math specialist."

      Process.put(:mock_response_generator, fn _messages ->
        {:ok, %GatewayResponse{content: "DONE", tool_calls: [], object: nil}}
      end)

      solver = IterativeProblemSolver.new(broker, system_prompt: custom_prompt)

      # We can't easily verify the system prompt was used in this mock,
      # but we can verify the solver was created with it
      assert solver.system_prompt == custom_prompt

      assert {:ok, _result} = IterativeProblemSolver.solve(solver, "Math problem")
    end

    test "uses custom temperature", %{broker: broker} do
      Process.put(:mock_response_generator, fn _messages ->
        {:ok, %GatewayResponse{content: "DONE", tool_calls: [], object: nil}}
      end)

      solver = IterativeProblemSolver.new(broker, temperature: 0.5)

      assert solver.temperature == 0.5

      assert {:ok, _result} = IterativeProblemSolver.solve(solver, "Task")
    end
  end

  describe "solve/2 - completion keywords" do
    test "detects 'done' in middle of sentence", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 ->
            {:ok,
             %GatewayResponse{content: "I'm done with this task.", tool_calls: [], object: nil}}

          2 ->
            {:ok, %GatewayResponse{content: "Summary", tool_calls: [], object: nil}}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Task")
      assert result == "Summary"
    end

    test "detects 'fail' in middle of sentence", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          1 ->
            {:ok,
             %GatewayResponse{content: "This will fail eventually.", tool_calls: [], object: nil}}

          2 ->
            {:ok, %GatewayResponse{content: "Failure", tool_calls: [], object: nil}}

          _ ->
            {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Task")
      assert result == "Failure"
    end

    test "doesn't false-trigger on words containing 'done' or 'fail'", %{broker: broker} do
      Process.put(:call_count, 0)

      Process.put(:mock_response_generator, fn messages ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        user_messages = Enum.filter(messages, fn msg -> msg.role == :user end)

        case length(user_messages) do
          # These words contain 'done' or 'fail' but shouldn't trigger
          1 -> {:ok, %GatewayResponse{content: "abandoned", tool_calls: [], object: nil}}
          2 -> {:ok, %GatewayResponse{content: "unfailing", tool_calls: [], object: nil}}
          3 -> {:ok, %GatewayResponse{content: "DONE", tool_calls: [], object: nil}}
          4 -> {:ok, %GatewayResponse{content: "Summary", tool_calls: [], object: nil}}
          _ -> {:ok, %GatewayResponse{content: "Unexpected", tool_calls: [], object: nil}}
        end
      end)

      solver = IterativeProblemSolver.new(broker, max_iterations: 5)

      assert {:ok, result} = IterativeProblemSolver.solve(solver, "Task")
      assert result == "Summary"

      # Should have gone through iterations until explicit DONE
      assert Process.get(:call_count) == 4
    end
  end
end
