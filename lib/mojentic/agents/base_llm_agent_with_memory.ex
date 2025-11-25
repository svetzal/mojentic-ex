defmodule Mojentic.Agents.BaseLLMAgentWithMemory do
  @moduledoc """
  An LLM agent that uses SharedWorkingMemory to remember information.

  This agent extends BaseLLMAgent with memory capabilities, allowing it to:
  - Access shared working memory in its system context
  - Learn new information from conversations
  - Merge learned information back into shared memory

  The agent automatically includes memory context in its prompts and extracts
  memory updates from LLM responses using structured output.

  ## Usage

      alias Mojentic.Context.SharedWorkingMemory
      alias Mojentic.Agents.BaseLLMAgentWithMemory
      alias Mojentic.LLM.Broker

      # Create shared memory
      memory = SharedWorkingMemory.new(%{
        "User" => %{"name" => "Alice"}
      })

      # Create broker
      broker = Broker.new("qwen2.5:7b", Ollama)

      # Create agent with memory
      agent = BaseLLMAgentWithMemory.new(
        broker: broker,
        memory: memory,
        behaviour: "You are a helpful assistant.",
        instructions: "Answer questions and remember new facts.",
        response_model: %{
          "type" => "object",
          "required" => ["text"],
          "properties" => %{
            "text" => %{"type" => "string", "description" => "Your response"}
          }
        }
      )

      # Generate response - memory is automatically included
      {:ok, response, updated_memory} =
        BaseLLMAgentWithMemory.generate_response_with_memory(agent, "What's my name?")

  ## Examples

      # Create agent that remembers user preferences
      memory = SharedWorkingMemory.new(%{})
      broker = Broker.new("qwen2.5:7b", Ollama)

      agent = BaseLLMAgentWithMemory.new(
        broker: broker,
        memory: memory,
        behaviour: "You are a personal assistant.",
        instructions: "Help the user and remember their preferences.",
        response_model: %{
          "type" => "object",
          "required" => ["response"],
          "properties" => %{
            "response" => %{"type" => "string"}
          }
        }
      )

      {:ok, response, memory} =
        BaseLLMAgentWithMemory.generate_response_with_memory(
          agent,
          "I prefer dark mode and vim keybindings"
        )

      # Memory now contains user preferences

  """

  alias Mojentic.Context.SharedWorkingMemory
  alias Mojentic.LLM.{Broker, Message}

  @type t :: %__MODULE__{
          broker: Broker.t(),
          memory: SharedWorkingMemory.t(),
          behaviour: String.t(),
          instructions: String.t(),
          response_model: map(),
          tools: [module()] | nil
        }

  @enforce_keys [:broker, :memory, :behaviour, :instructions, :response_model]
  defstruct [:broker, :memory, :behaviour, :instructions, :response_model, :tools]

  @doc """
  Creates a new BaseLLMAgentWithMemory.

  ## Parameters

  - `opts`: Keyword list with:
    - `:broker` - LLM broker instance (required)
    - `:memory` - SharedWorkingMemory instance (required)
    - `:behaviour` - System message defining agent personality (required)
    - `:instructions` - Instructions for processing events (required)
    - `:response_model` - JSON schema for structured output (required)
    - `:tools` - List of tool modules (optional)

  ## Examples

      agent = BaseLLMAgentWithMemory.new(
        broker: broker,
        memory: memory,
        behaviour: "You are a helpful assistant.",
        instructions: "Answer questions and learn new facts.",
        response_model: %{
          "type" => "object",
          "required" => ["answer"],
          "properties" => %{
            "answer" => %{"type" => "string"}
          }
        }
      )

  """
  def new(opts) do
    broker = Keyword.fetch!(opts, :broker)
    memory = Keyword.fetch!(opts, :memory)
    behaviour = Keyword.fetch!(opts, :behaviour)
    instructions = Keyword.fetch!(opts, :instructions)
    response_model = Keyword.fetch!(opts, :response_model)
    tools = Keyword.get(opts, :tools)

    %__MODULE__{
      broker: broker,
      memory: memory,
      behaviour: behaviour,
      instructions: instructions,
      response_model: response_model,
      tools: tools
    }
  end

  @doc """
  Creates initial messages with behaviour, memory, and instructions.

  The messages include:
  1. System message with agent behaviour
  2. Memory context (what the agent remembers)
  3. User message with instructions

  ## Parameters

  - `agent` - The BaseLLMAgentWithMemory instance

  ## Returns

  List of Message structs.

  ## Examples

      messages = BaseLLMAgentWithMemory.create_initial_messages(agent)
      #=> [
      #     %Message{role: :system, content: "You are..."},
      #     %Message{role: :user, content: "This is what you remember:..."},
      #     %Message{role: :user, content: "Answer questions..."}
      #   ]

  """
  def create_initial_messages(%__MODULE__{} = agent) do
    current_memory = SharedWorkingMemory.get_working_memory(agent.memory)
    memory_json = Jason.encode!(current_memory, pretty: true)

    [
      Message.system(agent.behaviour),
      Message.user("""
      This is what you remember:
      #{memory_json}

      Remember anything new you learn by storing it to your working memory in your response.
      """),
      Message.user(agent.instructions)
    ]
  end

  @doc """
  Generates a response with memory context and updates.

  This function:
  1. Creates initial messages with current memory
  2. Adds the user's content
  3. Requests structured output with memory field
  4. Merges memory updates back into SharedWorkingMemory
  5. Returns the response and updated memory

  ## Parameters

  - `agent` - The BaseLLMAgentWithMemory instance
  - `content` - The user's input string

  ## Returns

  - `{:ok, response_data, updated_memory}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, response, memory} =
        BaseLLMAgentWithMemory.generate_response_with_memory(
          agent,
          "My favorite color is blue"
        )

      # response contains the structured response (without memory field)
      # memory is updated SharedWorkingMemory with new information

  """
  def generate_response_with_memory(%__MODULE__{} = agent, content) when is_binary(content) do
    # Extend response model with memory field
    response_model_with_memory = add_memory_field(agent.response_model, agent.memory)

    # Create messages
    messages = create_initial_messages(agent)
    messages = messages ++ [Message.user(content)]

    # Generate structured response (note: tools not supported with structured output)
    case Broker.generate_object(agent.broker, messages, response_model_with_memory) do
      {:ok, response_map} ->
        # Extract memory and update SharedWorkingMemory
        {memory_data, response_data} = Map.pop(response_map, "memory", %{})
        updated_memory = SharedWorkingMemory.merge_to_working_memory(agent.memory, memory_data)

        {:ok, response_data, updated_memory}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Updates an agent's memory reference.

  Returns a new agent struct with the updated memory.

  ## Parameters

  - `agent` - The BaseLLMAgentWithMemory instance
  - `memory` - The new SharedWorkingMemory instance

  ## Examples

      agent = BaseLLMAgentWithMemory.update_memory(agent, new_memory)

  """
  def update_memory(%__MODULE__{} = agent, %SharedWorkingMemory{} = memory) do
    %{agent | memory: memory}
  end

  # Adds memory field to response model schema
  defp add_memory_field(base_model, memory) do
    current_memory = SharedWorkingMemory.get_working_memory(memory)

    # Get existing properties and required fields
    properties = Map.get(base_model, "properties", %{})
    required = Map.get(base_model, "required", [])

    # Add memory property
    memory_property = %{
      "type" => "object",
      "description" => "Add anything new that you have learned here.",
      "default" => current_memory
    }

    updated_properties = Map.put(properties, "memory", memory_property)

    # Update the model
    base_model
    |> Map.put("properties", updated_properties)
    |> Map.put("required", required)
  end
end
