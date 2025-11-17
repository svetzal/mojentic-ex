defmodule Mojentic.Agents.AsyncLLMAgent do
  @moduledoc """
  Asynchronous agent that uses an LLM to generate responses.

  This module provides a reusable pattern for creating async agents that
  interact with language models. It wraps the synchronous `Mojentic.LLM.Broker`
  operations in async tasks to avoid blocking the dispatcher.

  ## Features

  - **Behaviour** - System prompt defining agent personality
  - **Response Model** - JSON schema for structured output
  - **Tools** - List of tools available to the LLM
  - **Async Generation** - Non-blocking LLM calls

  ## Usage

  You can use this module in two ways:

  1. **Direct instantiation** with `new/1` (returns a map with behaviour)
  2. **Implementation helper** with `use Mojentic.Agents.AsyncLLMAgent` in your module

  ## Examples

      # Option 1: Direct instantiation
      defmodule MyAgent do
        @behaviour Mojentic.Agents.BaseAsyncAgent

        def init(broker) do
          AsyncLLMAgent.new(
            broker: broker,
            behaviour: "You are a helpful fact-checker.",
            response_model: %{
              "type" => "object",
              "properties" => %{
                "facts" => %{"type" => "array", "items" => %{"type" => "string"}}
              }
            }
          )
        end

        @impl true
        def receive_event_async(event) do
          agent = init(broker)
          prompt = "Check facts about: \#{event.question}"
          {:ok, response} = AsyncLLMAgent.generate_response(agent, prompt)
          {:ok, [create_fact_event(response, event.correlation_id)]}
        end
      end

      # Option 2: Using the module directly
      defmodule FactChecker do
        use Mojentic.Agents.AsyncLLMAgent

        def init(broker) do
          new(
            broker: broker,
            behaviour: "You are a fact-checker.",
            response_model: fact_schema()
          )
        end
      end

  """

  alias Mojentic.LLM.{Broker, Message}

  @type t :: %__MODULE__{
          broker: Broker.t(),
          behaviour: String.t(),
          response_model: map() | nil,
          tools: [module()] | nil
        }

  @enforce_keys [:broker, :behaviour]
  defstruct [:broker, :behaviour, :response_model, :tools]

  @doc """
  Creates a new AsyncLLMAgent configuration.

  ## Parameters

  - `opts` - Keyword list with:
    - `:broker` - LLM broker instance (required)
    - `:behaviour` - System prompt defining agent behavior (required)
    - `:response_model` - JSON schema for structured output (optional)
    - `:tools` - List of tool modules (optional)

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)

      agent = AsyncLLMAgent.new(
        broker: broker,
        behaviour: "You are a helpful assistant.",
        response_model: %{
          "type" => "object",
          "properties" => %{
            "answer" => %{"type" => "string"},
            "confidence" => %{"type" => "number"}
          }
        }
      )

  """
  def new(opts) do
    broker = Keyword.fetch!(opts, :broker)
    behaviour = Keyword.fetch!(opts, :behaviour)
    response_model = Keyword.get(opts, :response_model)
    tools = Keyword.get(opts, :tools)

    %__MODULE__{
      broker: broker,
      behaviour: behaviour,
      response_model: response_model,
      tools: tools
    }
  end

  @doc """
  Creates initial messages from the agent's behaviour.

  Returns a list containing the system message with the agent's behaviour.

  ## Examples

      iex> agent = AsyncLLMAgent.new(broker: broker, behaviour: "You are helpful.")
      iex> AsyncLLMAgent.create_initial_messages(agent)
      [%Message{role: :system, content: "You are helpful."}]

  """
  def create_initial_messages(%__MODULE__{behaviour: behaviour}) do
    [Message.system(behaviour)]
  end

  @doc """
  Generates a response from the LLM asynchronously.

  This function wraps the synchronous broker call in a Task to avoid blocking.
  It handles both structured output (via response_model) and free-form generation.

  ## Parameters

  - `agent` - The AsyncLLMAgent configuration
  - `content` - The user prompt string

  ## Returns

  - `{:ok, response}` - The LLM response (string or parsed object)
  - `{:error, reason}` - Generation failed

  ## Examples

      {:ok, response} = AsyncLLMAgent.generate_response(agent, "What is 2+2?")

      # With structured output
      {:ok, %{"answer" => "4", "confidence" => 1.0}} =
        AsyncLLMAgent.generate_response(agent, "What is 2+2?")

  """
  def generate_response(%__MODULE__{} = agent, content) when is_binary(content) do
    Task.async(fn ->
      messages = create_initial_messages(agent)
      messages = messages ++ [Message.user(content)]

      case agent.response_model do
        nil ->
          # Free-form text - use broker and unwrap to string
          case Broker.generate(agent.broker, messages, agent.tools) do
            {:ok, text_content} -> {:ok, text_content}
            error -> error
          end

        schema ->
          # Structured output - call gateway directly to preserve GatewayResponse
          agent.broker.gateway.complete_object(
            agent.broker.model,
            messages,
            schema,
            %Mojentic.LLM.CompletionConfig{}
          )
      end
    end)
    |> Task.await(:infinity)
  end

  @doc """
  Enables using this module in your own agent modules.

  When you `use Mojentic.Agents.AsyncLLMAgent`, you get helper functions
  for working with async LLM agents in your own implementations.

  ## Example

      defmodule MyFactChecker do
        use Mojentic.Agents.AsyncLLMAgent

        @behaviour Mojentic.Agents.BaseAsyncAgent

        def init(broker) do
          new(
            broker: broker,
            behaviour: "You are a fact-checker.",
            response_model: my_schema()
          )
        end

        @impl true
        def receive_event_async(event) do
          agent = init(get_broker())
          {:ok, response} = generate_response(agent, event.question)
          {:ok, [create_event(response, event)]}
        end
      end

  """
  defmacro __using__(_opts) do
    quote do
      alias Mojentic.Agents.AsyncLLMAgent

      def new(opts), do: AsyncLLMAgent.new(opts)
      def create_initial_messages(agent), do: AsyncLLMAgent.create_initial_messages(agent)
      def generate_response(agent, content), do: AsyncLLMAgent.generate_response(agent, content)

      defoverridable new: 1, create_initial_messages: 1, generate_response: 2
    end
  end
end
