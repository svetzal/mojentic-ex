defmodule Mojentic.Agents.BaseLLMAgent do
  @moduledoc """
  A basic LLM agent with behaviour, tools, and broker.

  This agent encapsulates an LLM broker, a set of tools, and behavioural
  instructions, providing a complete agent that can be used standalone or
  wrapped as a tool for delegation patterns.

  ## Examples

      alias Mojentic.Agents.BaseLLMAgent
      alias Mojentic.LLM.Broker

      broker = Broker.new("qwen3:7b", Mojentic.LLM.Gateways.Ollama)

      agent = BaseLLMAgent.new(
        broker: broker,
        behaviour: "You are a helpful historian specializing in ancient civilizations.",
        tools: [DateResolver]
      )

      {:ok, response} = BaseLLMAgent.generate_response(agent, "When was Rome founded?")

  """

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Message

  @type t :: %__MODULE__{
          broker: Broker.t(),
          behaviour: String.t(),
          tools: [module()] | nil
        }

  @enforce_keys [:broker, :behaviour]
  defstruct [:broker, :behaviour, :tools]

  @doc """
  Creates a new BaseLLMAgent.

  ## Parameters

  - `opts`: Keyword list with:
    - `:broker` - LLM broker instance (required)
    - `:behaviour` - System message defining agent's personality and role (required)
    - `:tools` - List of tool modules (optional, default: nil)

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)

      agent = BaseLLMAgent.new(
        broker: broker,
        behaviour: "You are a helpful assistant.",
        tools: [WeatherTool]
      )

  """
  def new(opts) do
    broker = Keyword.fetch!(opts, :broker)
    behaviour = Keyword.fetch!(opts, :behaviour)
    tools = Keyword.get(opts, :tools)

    %__MODULE__{
      broker: broker,
      behaviour: behaviour,
      tools: tools
    }
  end

  @doc """
  Creates initial messages from the agent's behaviour.

  Returns a list containing the system message with the agent's behaviour.

  ## Examples

      iex> agent = BaseLLMAgent.new(broker: broker, behaviour: "You are helpful.")
      iex> BaseLLMAgent.create_initial_messages(agent)
      [%Message{role: :system, content: "You are helpful."}]

  """
  def create_initial_messages(%__MODULE__{behaviour: behaviour}) do
    [Message.system(behaviour)]
  end

  @doc """
  Generates a response from the agent for the given input.

  Creates initial messages from the agent's behaviour, appends the user input,
  and calls the broker to generate a response using the agent's tools.

  ## Parameters

  - `agent`: The BaseLLMAgent instance
  - `content`: The user input string

  ## Returns

  - `{:ok, response}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, response} = BaseLLMAgent.generate_response(agent, "What is 2+2?")

  """
  def generate_response(%__MODULE__{} = agent, content) when is_binary(content) do
    messages = create_initial_messages(agent)
    messages = messages ++ [Message.user(content)]

    Broker.generate(agent.broker, messages, agent.tools)
  end
end
