defmodule Mojentic.Agents.BaseLLMAgentWithMemoryTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.BaseLLMAgentWithMemory
  alias Mojentic.Context.SharedWorkingMemory
  alias Mojentic.LLM.{Broker, Message}

  doctest BaseLLMAgentWithMemory

  # Mock broker for testing
  defmodule MockBroker do
    @moduledoc false

    def new do
      %Broker{
        model: "mock-model",
        gateway: __MODULE__
      }
    end

    def complete_object(_model, _messages, _response_model, _config) do
      # Return mock response with memory field
      {:ok,
       %Mojentic.LLM.GatewayResponse{
         content: nil,
         tool_calls: nil,
         object: %{
           "text" => "Mock response",
           "memory" => %{
             "learned" => "new information"
           }
         }
       }}
    end
  end

  setup do
    memory =
      SharedWorkingMemory.new(%{
        "User" => %{
          "name" => "Alice"
        }
      })

    broker = MockBroker.new()

    response_model = %{
      "type" => "object",
      "required" => ["text"],
      "properties" => %{
        "text" => %{"type" => "string", "description" => "Response text"}
      }
    }

    {:ok, memory: memory, broker: broker, response_model: response_model}
  end

  describe "new/1" do
    test "creates agent with required fields", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      assert %BaseLLMAgentWithMemory{} = agent
      assert agent.broker == broker
      assert agent.memory == memory
      assert agent.behaviour == "You are helpful."
      assert agent.instructions == "Answer questions."
      assert agent.response_model == response_model
      assert agent.tools == nil
    end

    test "creates agent with tools", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model,
          tools: [SomeTool]
        )

      assert agent.tools == [SomeTool]
    end

    test "raises when required fields missing" do
      assert_raise KeyError, fn ->
        BaseLLMAgentWithMemory.new(broker: MockBroker.new())
      end
    end
  end

  describe "create_initial_messages/1" do
    test "includes system message with behaviour", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are a test assistant.",
          instructions: "Follow instructions.",
          response_model: response_model
        )

      messages = BaseLLMAgentWithMemory.create_initial_messages(agent)

      assert length(messages) == 3
      assert %Message{role: :system, content: "You are a test assistant."} = Enum.at(messages, 0)
    end

    test "includes memory context in user message", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      messages = BaseLLMAgentWithMemory.create_initial_messages(agent)

      memory_message = Enum.at(messages, 1)
      assert memory_message.role == :user
      assert String.contains?(memory_message.content, "This is what you remember:")
      assert String.contains?(memory_message.content, "Alice")
      assert String.contains?(memory_message.content, "working memory")
    end

    test "includes instructions in user message", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Be concise and accurate.",
          response_model: response_model
        )

      messages = BaseLLMAgentWithMemory.create_initial_messages(agent)

      instructions_message = Enum.at(messages, 2)
      assert instructions_message.role == :user
      assert instructions_message.content == "Be concise and accurate."
    end

    test "formats memory as JSON", %{broker: broker, response_model: response_model} do
      memory =
        SharedWorkingMemory.new(%{
          "nested" => %{
            "data" => "value"
          }
        })

      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      messages = BaseLLMAgentWithMemory.create_initial_messages(agent)

      memory_message = Enum.at(messages, 1)
      assert String.contains?(memory_message.content, ~s("nested"))
      assert String.contains?(memory_message.content, ~s("data"))
      assert String.contains?(memory_message.content, ~s("value"))
    end
  end

  describe "update_memory/2" do
    test "updates agent's memory reference", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      new_memory = SharedWorkingMemory.new(%{"different" => "data"})
      updated_agent = BaseLLMAgentWithMemory.update_memory(agent, new_memory)

      assert updated_agent.memory == new_memory
      assert updated_agent.broker == agent.broker
      assert updated_agent.behaviour == agent.behaviour
    end
  end

  describe "generate_response_with_memory/2" do
    test "returns response and updated memory", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      {:ok, response, updated_memory} =
        BaseLLMAgentWithMemory.generate_response_with_memory(agent, "Tell me something")

      assert response == %{"text" => "Mock response"}
      assert %SharedWorkingMemory{} = updated_memory

      memory_data = SharedWorkingMemory.get_working_memory(updated_memory)
      assert memory_data["User"]["name"] == "Alice"
      assert memory_data["learned"] == "new information"
    end

    test "removes memory field from response", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      {:ok, response, _memory} =
        BaseLLMAgentWithMemory.generate_response_with_memory(agent, "Hello")

      refute Map.has_key?(response, "memory")
    end

    test "merges new memory with existing", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      {:ok, _response, updated_memory} =
        BaseLLMAgentWithMemory.generate_response_with_memory(agent, "Question")

      memory_data = SharedWorkingMemory.get_working_memory(updated_memory)
      # Original data preserved
      assert memory_data["User"]["name"] == "Alice"
      # New data added
      assert memory_data["learned"] == "new information"
    end
  end

  describe "response model with memory field" do
    test "extends response model schema with memory", %{
      memory: memory,
      broker: broker,
      response_model: response_model
    } do
      # Create mock that captures the model
      defmodule CapturingBroker do
        def complete_object(_model, _messages, schema, _config) do
          send(self(), {:model_captured, schema})

          {:ok,
           %Mojentic.LLM.GatewayResponse{
             content: nil,
             tool_calls: nil,
             object: %{
               "text" => "Response",
               "memory" => %{}
             }
           }}
        end
      end

      capturing_broker = %Broker{model: "test", gateway: CapturingBroker}

      agent =
        BaseLLMAgentWithMemory.new(
          broker: capturing_broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      BaseLLMAgentWithMemory.generate_response_with_memory(agent, "Test")

      assert_received {:model_captured, captured_model}
      assert Map.has_key?(captured_model["properties"], "memory")
      assert captured_model["properties"]["memory"]["type"] == "object"
      assert String.contains?(captured_model["properties"]["memory"]["description"], "learned")
    end
  end

  describe "error handling" do
    test "returns error when broker fails", %{memory: memory, response_model: response_model} do
      defmodule FailingBroker do
        def complete_object(_model, _messages, _schema, _config) do
          {:error, :connection_failed}
        end
      end

      failing_broker = %Broker{model: "test", gateway: FailingBroker}

      agent =
        BaseLLMAgentWithMemory.new(
          broker: failing_broker,
          memory: memory,
          behaviour: "You are helpful.",
          instructions: "Answer questions.",
          response_model: response_model
        )

      assert {:error, :connection_failed} =
               BaseLLMAgentWithMemory.generate_response_with_memory(agent, "Test")
    end
  end
end
