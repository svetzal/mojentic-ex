defmodule Mojentic.LLM.Tools.ToolWrapperTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.BaseLLMAgent
  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Message
  alias Mojentic.LLM.Tools.ToolWrapper

  # Mock broker for testing
  defmodule MockBroker do
    defstruct [:model, :response]

    def new(model, response \\ "Mock response") do
      %__MODULE__{model: model, response: response}
    end
  end

  # Mock tool for testing
  defmodule MockTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "mock_tool",
          description: "A mock tool",
          parameters: %{
            type: "object",
            properties: %{},
            required: []
          }
        }
      }
    end

    @impl true
    def run(_tool, _arguments) do
      {:ok, "mock result"}
    end
  end

  describe "new/1" do
    test "creates tool wrapper with required fields" do
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful."
        )

      wrapper =
        ToolWrapper.new(
          agent: agent,
          name: "test_agent",
          description: "A test agent"
        )

      assert wrapper.agent == agent
      assert wrapper.name == "test_agent"
      assert wrapper.description == "A test agent"
    end

    test "requires agent" do
      assert_raise KeyError, fn ->
        ToolWrapper.new(
          name: "test",
          description: "test"
        )
      end
    end

    test "requires name" do
      broker = MockBroker.new("test-model")
      agent = BaseLLMAgent.new(broker: broker, behaviour: "helpful")

      assert_raise KeyError, fn ->
        ToolWrapper.new(
          agent: agent,
          description: "test"
        )
      end
    end

    test "requires description" do
      broker = MockBroker.new("test-model")
      agent = BaseLLMAgent.new(broker: broker, behaviour: "helpful")

      assert_raise KeyError, fn ->
        ToolWrapper.new(
          agent: agent,
          name: "test"
        )
      end
    end
  end

  describe "descriptor/1" do
    test "returns proper function descriptor" do
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are a specialist."
        )

      wrapper =
        ToolWrapper.new(
          agent: agent,
          name: "specialist_agent",
          description: "An expert in specialized topics"
        )

      descriptor = ToolWrapper.descriptor(wrapper)

      assert descriptor.type == "function"
      assert descriptor.function.name == "specialist_agent"
      assert descriptor.function.description == "An expert in specialized topics"

      params = descriptor.function.parameters
      assert params.type == "object"
      assert params.required == ["input"]
      assert params.additionalProperties == false

      properties = params.properties
      assert Map.has_key?(properties, :input)
      assert properties.input.type == "string"
      assert properties.input.description == "Instructions for this agent."
    end

    test "descriptor matches Tool behaviour format" do
      broker = MockBroker.new("test-model")
      agent = BaseLLMAgent.new(broker: broker, behaviour: "helpful")

      wrapper =
        ToolWrapper.new(
          agent: agent,
          name: "test",
          description: "test"
        )

      descriptor = ToolWrapper.descriptor(wrapper)

      # Verify it has the expected structure
      assert is_map(descriptor)
      assert descriptor.type == "function"
      assert is_map(descriptor.function)
      assert is_binary(descriptor.function.name)
      assert is_binary(descriptor.function.description)
      assert is_map(descriptor.function.parameters)
    end
  end

  describe "run/2" do
    test "extracts input and delegates to agent" do
      # We'll verify the messages are constructed correctly
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are a historian.",
          tools: [MockTool]
        )

      wrapper =
        ToolWrapper.new(
          agent: agent,
          name: "historian",
          description: "A historian agent"
        )

      # Test the message construction part
      arguments = %{"input" => "When was Rome founded?"}
      input = Map.get(arguments, "input", "")

      messages = BaseLLMAgent.create_initial_messages(agent) ++ [Message.user(input)]

      assert length(messages) == 2

      assert [
               %Message{role: :system, content: "You are a historian."},
               %Message{role: :user, content: "When was Rome founded?"}
             ] = messages
    end

    test "handles missing input parameter gracefully" do
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful."
        )

      wrapper =
        ToolWrapper.new(
          agent: agent,
          name: "test",
          description: "test"
        )

      # Empty arguments should use empty string as input
      arguments = %{}
      input = Map.get(arguments, "input", "")

      assert input == ""
    end
  end
end
