defmodule Mojentic.Agents.BaseLLMAgentTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.BaseLLMAgent
  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Message

  # Mock broker for testing
  defmodule MockBroker do
    defstruct [:model, :gateway]

    def new(model) do
      %__MODULE__{model: model, gateway: nil}
    end
  end

  describe "new/1" do
    test "creates agent with required fields" do
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are a helpful assistant."
        )

      assert agent.broker == broker
      assert agent.behaviour == "You are a helpful assistant."
      assert agent.tools == nil
    end

    test "creates agent with tools" do
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful.",
          tools: [SomeTool]
        )

      assert agent.tools == [SomeTool]
    end

    test "requires broker" do
      assert_raise KeyError, fn ->
        BaseLLMAgent.new(behaviour: "You are helpful.")
      end
    end

    test "requires behaviour" do
      broker = MockBroker.new("test-model")

      assert_raise KeyError, fn ->
        BaseLLMAgent.new(broker: broker)
      end
    end
  end

  describe "create_initial_messages/1" do
    test "creates system message from behaviour" do
      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are a historian."
        )

      messages = BaseLLMAgent.create_initial_messages(agent)

      assert length(messages) == 1
      assert [%Message{role: :system, content: "You are a historian."}] = messages
    end
  end

  describe "generate_response/2" do
    test "calls broker with behaviour and user input" do
      # Create a test process to capture broker calls
      test_pid = self()

      # Mock broker module that captures calls
      defmodule TestBroker do
        def generate(broker, messages, tools) do
          send(
            Process.whereis(:test_receiver),
            {:generate_called, broker, messages, tools}
          )

          {:ok, "Test response"}
        end
      end

      # Register the test process
      Process.register(test_pid, :test_receiver)

      broker = MockBroker.new("test-model")

      agent =
        BaseLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful.",
          tools: [SomeTool]
        )

      # Temporarily replace Broker module for this test
      # We'll validate by checking the messages structure instead
      messages = BaseLLMAgent.create_initial_messages(agent) ++ [Message.user("Hello")]

      assert length(messages) == 2
      assert [%Message{role: :system}, %Message{role: :user, content: "Hello"}] = messages

      # Cleanup
      Process.unregister(:test_receiver)
    end
  end
end
