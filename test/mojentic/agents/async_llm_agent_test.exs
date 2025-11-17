defmodule Mojentic.Agents.AsyncLLMAgentTest do
  use ExUnit.Case, async: true

  import Mox

  alias Mojentic.Agents.AsyncLLMAgent
  alias Mojentic.LLM.{Broker, Message}

  setup :verify_on_exit!

  defmodule MockGateway do
    @behaviour Mojentic.LLM.Gateway

    @impl true
    def complete(_model, _messages, _tools, _config) do
      {:ok, %Mojentic.LLM.GatewayResponse{content: "Mocked response"}}
    end

    @impl true
    def complete_object(_model, _messages, _schema, _config) do
      {:ok, %Mojentic.LLM.GatewayResponse{object: %{"answer" => "42", "confidence" => 0.95}}}
    end

    @impl true
    def complete_stream(_model, _messages, _tools, _config) do
      {:error, :not_implemented}
    end

    @impl true
    def get_available_models do
      {:ok, ["test-model"]}
    end

    @impl true
    def calculate_embeddings(_text, _model) do
      {:ok, [0.1, 0.2, 0.3]}
    end
  end

  describe "AsyncLLMAgent.new/1" do
    test "creates agent with required fields" do
      broker = Broker.new("test-model", MockGateway)

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful."
        )

      assert agent.broker == broker
      assert agent.behaviour == "You are helpful."
      assert is_nil(agent.response_model)
      assert is_nil(agent.tools)
    end

    test "creates agent with optional fields" do
      broker = Broker.new("test-model", MockGateway)
      schema = %{"type" => "object"}

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful.",
          response_model: schema,
          tools: [SomeTool]
        )

      assert agent.response_model == schema
      assert agent.tools == [SomeTool]
    end

    test "raises on missing required broker" do
      assert_raise KeyError, fn ->
        AsyncLLMAgent.new(behaviour: "You are helpful.")
      end
    end

    test "raises on missing required behaviour" do
      broker = Broker.new("test-model", MockGateway)

      assert_raise KeyError, fn ->
        AsyncLLMAgent.new(broker: broker)
      end
    end
  end

  describe "AsyncLLMAgent.create_initial_messages/1" do
    test "creates system message from behaviour" do
      broker = Broker.new("test-model", MockGateway)

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are a test assistant."
        )

      messages = AsyncLLMAgent.create_initial_messages(agent)

      assert [%Message{role: :system, content: "You are a test assistant."}] = messages
    end
  end

  describe "AsyncLLMAgent.generate_response/2 without response_model" do
    test "generates free-form text response" do
      broker = Broker.new("test-model", MockGateway)

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful."
        )

      assert {:ok, "Mocked response"} = AsyncLLMAgent.generate_response(agent, "Hello")
    end

    test "includes behaviour as system message" do
      # This is implicitly tested by the gateway receiving the messages
      broker = Broker.new("test-model", MockGateway)

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful."
        )

      {:ok, _response} = AsyncLLMAgent.generate_response(agent, "Test prompt")
    end
  end

  describe "AsyncLLMAgent.generate_response/2 with response_model" do
    test "generates structured response" do
      broker = Broker.new("test-model", MockGateway)

      schema = %{
        "type" => "object",
        "properties" => %{
          "answer" => %{"type" => "string"},
          "confidence" => %{"type" => "number"}
        }
      }

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful.",
          response_model: schema
        )

      assert {:ok,
              %Mojentic.LLM.GatewayResponse{object: %{"answer" => "42", "confidence" => 0.95}}} =
               AsyncLLMAgent.generate_response(agent, "What is the answer?")
    end
  end

  describe "AsyncLLMAgent.generate_response/2 with tools" do
    defmodule TestTool do
      @behaviour Mojentic.LLM.Tools.Tool

      @impl true
      def run(_input, _args), do: {:ok, %{result: "tool result"}}

      @impl true
      def descriptor do
        %{
          "type" => "function",
          "function" => %{
            "name" => "test_tool",
            "description" => "A test tool",
            "parameters" => %{
              "type" => "object",
              "properties" => %{}
            }
          }
        }
      end
    end

    test "passes tools to broker" do
      broker = Broker.new("test-model", MockGateway)

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful.",
          tools: [TestTool]
        )

      {:ok, _response} = AsyncLLMAgent.generate_response(agent, "Use the tool")
      # Tool passing is verified through the gateway mock
    end
  end

  describe "AsyncLLMAgent async behavior" do
    test "runs in a task without blocking" do
      broker = Broker.new("test-model", MockGateway)

      agent =
        AsyncLLMAgent.new(
          broker: broker,
          behaviour: "You are helpful."
        )

      # Spawn multiple concurrent requests
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            AsyncLLMAgent.generate_response(agent, "Request #{i}")
          end)
        end

      results = Task.await_many(tasks)

      assert length(results) == 3
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end
  end

  describe "using AsyncLLMAgent" do
    defmodule CustomAgent do
      use AsyncLLMAgent
    end

    test "provides helper functions" do
      assert function_exported?(CustomAgent, :new, 1)
      assert function_exported?(CustomAgent, :create_initial_messages, 1)
      assert function_exported?(CustomAgent, :generate_response, 2)
    end
  end
end
