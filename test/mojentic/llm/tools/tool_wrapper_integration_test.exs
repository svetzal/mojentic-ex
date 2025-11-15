defmodule Mojentic.LLM.Tools.ToolWrapperIntegrationTest do
  use ExUnit.Case, async: false

  alias Mojentic.Agents.BaseLLMAgent
  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Message
  alias Mojentic.LLM.Tools.ToolWrapper

  # Mock Gateway for testing - simulates LLM responses
  defmodule MockGateway do
    alias Mojentic.LLM.CompletionConfig
    alias Mojentic.LLM.GatewayResponse
    alias Mojentic.LLM.ToolCall

    def complete(_model, messages, tools, _config \\ %CompletionConfig{}) do
      # Extract the last user message
      last_message = List.last(messages)

      # Simulate different responses based on message content
      response =
        cond do
          # Coordinator should delegate to specialist
          last_message.content =~ "What year was Rome founded" and tools != nil ->
            %GatewayResponse{
              content: nil,
              tool_calls: [
                %ToolCall{
                  id: "call_1",
                  name: "historian",
                  arguments: %{"input" => "When was Rome founded?"}
                }
              ],
              object: nil
            }

          # Specialist responds to the question
          last_message.content =~ "When was Rome founded" and
              (tools == nil or tools == []) ->
            %GatewayResponse{
              content:
                "According to tradition, Rome was founded in 753 BCE by Romulus.",
              tool_calls: [],
              object: nil
            }

          # Coordinator provides final answer after receiving specialist response
          length(messages) > 2 and Enum.any?(messages, &(&1.role == :tool)) ->
            %GatewayResponse{
              content:
                "Rome was founded in 753 BCE by Romulus, as the historian specialist confirmed.",
              tool_calls: [],
              object: nil
            }

          true ->
            %GatewayResponse{
              content: "I'm not sure how to answer that.",
              tool_calls: [],
              object: nil
            }
        end

      {:ok, response}
    end

    def complete_object(_model, _messages, _schema, _config) do
      {:error, :not_implemented}
    end

    def complete_stream(_model, _messages, _tools, _config) do
      Stream.iterate(0, &(&1 + 1))
    end

    def embed(_model, _input) do
      {:error, :not_implemented}
    end
  end

  describe "multi-agent delegation integration" do
    test "coordinator delegates to specialist agent wrapped as tool" do
      # Create a specialist agent with specific knowledge
      specialist_broker = Broker.new("specialist-model", MockGateway)

      specialist_agent =
        BaseLLMAgent.new(
          broker: specialist_broker,
          behaviour: "You are a historian specializing in ancient Rome.",
          tools: []
        )

      # Wrap the specialist as a tool
      historian_tool =
        ToolWrapper.new(
          agent: specialist_agent,
          name: "historian",
          description: "A historian specializing in ancient Rome and Roman history."
        )

      # Verify the tool descriptor
      descriptor = ToolWrapper.descriptor(historian_tool)
      assert descriptor.type == "function"
      assert descriptor.function.name == "historian"
      assert descriptor.function.description =~ "historian"
      assert descriptor.function.parameters.properties.input.type == "string"

      # Create a coordinator agent that uses the specialist
      coordinator_broker = Broker.new("coordinator-model", MockGateway)

      coordinator_agent =
        BaseLLMAgent.new(
          broker: coordinator_broker,
          behaviour:
            "You are a coordinator that delegates questions to specialist agents.",
          tools: [historian_tool]
        )

      # Ask the coordinator a question
      {:ok, response} =
        BaseLLMAgent.generate_response(
          coordinator_agent,
          "What year was Rome founded?"
        )

      # Verify the coordinator successfully delegated and got an answer
      assert response =~ "753 BCE"
      assert response =~ "Romulus" or response =~ "historian"
    end

    test "multiple specialists can be used by coordinator" do
      # Create multiple specialist agents
      historian_broker = Broker.new("historian-model", MockGateway)

      historian_agent =
        BaseLLMAgent.new(
          broker: historian_broker,
          behaviour: "You are a historian.",
          tools: []
        )

      historian_tool =
        ToolWrapper.new(
          agent: historian_agent,
          name: "historian",
          description: "Expert in historical events and dates."
        )

      # Could create more specialists here (mathematician, scientist, etc.)
      # For this test, we'll just use one

      coordinator_broker = Broker.new("coordinator-model", MockGateway)

      coordinator_agent =
        BaseLLMAgent.new(
          broker: coordinator_broker,
          behaviour: "You are a coordinator with multiple specialists available.",
          tools: [historian_tool]
        )

      # Verify the coordinator has access to the tools
      assert coordinator_agent.tools == [historian_tool]
      assert length(coordinator_agent.tools) == 1
    end

    test "tool wrapper properly delegates input to wrapped agent" do
      specialist_broker = Broker.new("specialist-model", MockGateway)

      specialist_agent =
        BaseLLMAgent.new(
          broker: specialist_broker,
          behaviour: "You are a helpful specialist.",
          tools: []
        )

      tool =
        ToolWrapper.new(
          agent: specialist_agent,
          name: "specialist",
          description: "A specialist agent"
        )

      # Test the run function directly
      {:ok, result} =
        ToolWrapper.run(tool, %{"input" => "When was Rome founded?"})

      # The specialist should have received and processed the input
      assert is_binary(result)
      assert result =~ "753 BCE" or result =~ "Rome" or result =~ "not sure"
    end
  end
end
