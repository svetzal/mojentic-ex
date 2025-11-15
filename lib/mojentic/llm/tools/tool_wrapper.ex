defmodule Mojentic.LLM.Tools.ToolWrapper do
  @moduledoc """
  Wraps a BaseLLMAgent as a Tool for delegation patterns.

  This allows agents to use other agents as tools, enabling complex
  multi-agent architectures where coordinator agents can delegate
  specialized tasks to expert agents.

  ## Examples

      # Create a specialist agent
      temporal_agent = BaseLLMAgent.new(
        broker: Broker.new("qwen3:7b", Ollama),
        behaviour: "You are a historian specializing in temporal reasoning.",
        tools: [DateResolver]
      )

      # Wrap it as a tool
      temporal_tool = ToolWrapper.new(
        agent: temporal_agent,
        name: "temporal_specialist",
        description: "A historian that can resolve dates and temporal queries."
      )

      # Use it in a coordinator agent
      coordinator = BaseLLMAgent.new(
        broker: Broker.new("qwen3:32b", Ollama),
        behaviour: "You are a coordinator that delegates to specialists.",
        tools: [temporal_tool]
      )

  """

  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.Agents.BaseLLMAgent
  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Message

  # Suppress behaviour warning - we implement descriptor/1 instead of descriptor/0
  @impl true
  def descriptor do
    raise "ToolWrapper.descriptor/0 should not be called directly. Use Tool.descriptor/1 with a ToolWrapper instance."
  end

  @type t :: %__MODULE__{
          agent: BaseLLMAgent.t(),
          name: String.t(),
          description: String.t()
        }

  @enforce_keys [:agent, :name, :description]
  defstruct [:agent, :name, :description]

  @doc """
  Creates a new ToolWrapper.

  ## Parameters

  - `opts`: Keyword list with:
    - `:agent` - BaseLLMAgent to wrap (required)
    - `:name` - Tool name for LLM function calling (required)
    - `:description` - Description of what the agent does (required)

  ## Examples

      tool = ToolWrapper.new(
        agent: my_agent,
        name: "specialist",
        description: "An expert in specialized topics"
      )

  """
  def new(opts) do
    agent = Keyword.fetch!(opts, :agent)
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)

    %__MODULE__{
      agent: agent,
      name: name,
      description: description
    }
  end

  @doc """
  Returns the tool descriptor for this wrapped agent.

  The descriptor is built dynamically from the instance's name and description.
  """
  def descriptor(%__MODULE__{name: name, description: description}) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: %{
            input: %{
              type: "string",
              description: "Instructions for this agent."
            }
          },
          required: ["input"],
          additionalProperties: false
        }
      }
    }
  end

  @impl true
  def run(%__MODULE__{agent: agent}, arguments) do
    input = Map.get(arguments, "input", "")

    # Create initial messages from agent's behaviour
    messages = BaseLLMAgent.create_initial_messages(agent)

    # Append the input as a user message
    messages = messages ++ [Message.user(input)]

    # Generate response using the agent's broker and tools
    case Broker.generate(agent.broker, messages, agent.tools) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
