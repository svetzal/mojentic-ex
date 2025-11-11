defmodule Mojentic.LLM.BrokerTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Message
  alias Mojentic.LLM.ToolCall

  # Mock gateway for testing
  defmodule MockGateway do
    @behaviour Mojentic.LLM.Gateway

    @impl true
    def complete(model, messages, tools, config) do
      # Store call info in process dictionary for assertions
      Process.put(:last_complete_call, %{
        model: model,
        messages: messages,
        tools: tools,
        config: config
      })

      case Process.get(:mock_response) do
        nil ->
          {:ok,
           %GatewayResponse{
             content: "Mock response",
             tool_calls: [],
             object: nil
           }}

        fun when is_function(fun) ->
          fun.()

        response ->
          response
      end
    end

    @impl true
    def complete_object(model, messages, schema, config) do
      Process.put(:last_complete_object_call, %{
        model: model,
        messages: messages,
        schema: schema,
        config: config
      })

      case Process.get(:mock_object_response) do
        nil ->
          {:ok,
           %GatewayResponse{
             content: nil,
             tool_calls: [],
             object: %{"test" => "value"}
           }}

        response ->
          response
      end
    end

    @impl true
    def get_available_models do
      {:ok, ["model1", "model2"]}
    end

    @impl true
    def calculate_embeddings(_model, _text) do
      {:ok, [0.1, 0.2, 0.3]}
    end
  end

  # Mock tool for testing
  defmodule MockTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(args) do
      case Map.get(args, "fail") do
        true -> {:error, {:tool_error, "Tool failed"}}
        _ -> {:ok, %{result: "tool executed"}}
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
            properties: %{}
          }
        }
      }
    end

    def matches?(name), do: name == "mock_tool"
  end

  setup do
    # Clear process dictionary before each test
    Process.delete(:mock_response)
    Process.delete(:mock_object_response)
    Process.delete(:last_complete_call)
    Process.delete(:last_complete_object_call)
    :ok
  end

  describe "new/2" do
    test "creates broker with model and gateway" do
      broker = Broker.new("test-model", MockGateway)

      assert broker.model == "test-model"
      assert broker.gateway == MockGateway
      assert is_binary(broker.correlation_id)
    end

    test "accepts custom correlation_id" do
      broker = Broker.new("test-model", MockGateway, "custom-123")

      assert broker.correlation_id == "custom-123"
    end
  end

  describe "generate/4" do
    test "generates text response" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Hello")]

      assert {:ok, response} = Broker.generate(broker, messages)
      assert response == "Mock response"

      call_info = Process.get(:last_complete_call)
      assert call_info.model == "test-model"
      assert call_info.messages == messages
    end

    test "handles empty content" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Hello")]

      Process.put(:mock_response, {
        :ok,
        %GatewayResponse{content: nil, tool_calls: [], object: nil}
      })

      assert {:ok, ""} = Broker.generate(broker, messages)
    end

    test "accepts custom config" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Hello")]
      config = %CompletionConfig{temperature: 0.5}

      Broker.generate(broker, messages, nil, config)

      call_info = Process.get(:last_complete_call)
      assert call_info.config.temperature == 0.5
    end

    test "handles tool calls" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Hello")]

      tool_call = %ToolCall{
        id: "call-1",
        name: "mock_tool",
        arguments: %{}
      }

      # Track call count to return different responses
      Process.put(:call_count, 0)

      # First call returns tool call, second returns final response
      Process.put(:mock_response, fn ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        if count == 0 do
          {:ok,
           %GatewayResponse{
             content: "",
             tool_calls: [tool_call],
             object: nil
           }}
        else
          {:ok,
           %GatewayResponse{
             content: "Final response after tool",
             tool_calls: [],
             object: nil
           }}
        end
      end)

      assert {:ok, response} = Broker.generate(broker, messages, [MockTool])
      assert response == "Final response after tool"
    end

    test "handles tool not found" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Hello")]

      tool_call = %ToolCall{
        id: "call-1",
        name: "unknown_tool",
        arguments: %{}
      }

      # Track call count to stop infinite recursion
      Process.put(:call_count, 0)

      Process.put(:mock_response, fn ->
        count = Process.get(:call_count, 0)
        Process.put(:call_count, count + 1)

        if count == 0 do
          {:ok,
           %GatewayResponse{
             content: "",
             tool_calls: [tool_call],
             object: nil
           }}
        else
          {:ok,
           %GatewayResponse{
             content: "Response after missing tool",
             tool_calls: [],
             object: nil
           }}
        end
      end)

      # Should log warning but continue
      assert {:ok, response} = Broker.generate(broker, messages, [MockTool])
      assert response == "Response after missing tool"
    end

    test "propagates gateway errors" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Hello")]

      Process.put(:mock_response, {:error, {:http_error, 500}})

      assert {:error, {:http_error, 500}} = Broker.generate(broker, messages)
    end
  end

  describe "generate_object/4" do
    test "generates structured response" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Generate object")]

      schema = %{
        type: "object",
        properties: %{
          test: %{type: "string"}
        }
      }

      assert {:ok, object} = Broker.generate_object(broker, messages, schema)
      assert object == %{"test" => "value"}

      call_info = Process.get(:last_complete_object_call)
      assert call_info.model == "test-model"
      assert call_info.schema == schema
    end

    test "returns error when no object in response" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Generate object")]
      schema = %{type: "object", properties: %{}}

      Process.put(:mock_object_response, {
        :ok,
        %GatewayResponse{content: nil, tool_calls: [], object: nil}
      })

      assert {:error, :invalid_response} = Broker.generate_object(broker, messages, schema)
    end

    test "accepts custom config" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Generate object")]
      schema = %{type: "object", properties: %{}}
      config = %CompletionConfig{temperature: 0.1}

      Broker.generate_object(broker, messages, schema, config)

      call_info = Process.get(:last_complete_object_call)
      assert call_info.config.temperature == 0.1
    end

    test "propagates gateway errors" do
      broker = Broker.new("test-model", MockGateway)
      messages = [Message.user("Generate object")]
      schema = %{type: "object", properties: %{}}

      Process.put(:mock_object_response, {:error, {:gateway_error, "Failed"}})

      assert {:error, {:gateway_error, "Failed"}} =
               Broker.generate_object(broker, messages, schema)
    end
  end
end
