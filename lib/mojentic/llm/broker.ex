defmodule Mojentic.LLM.Broker do
  @moduledoc """
  Main interface for LLM interactions.

  The broker manages communication with LLM providers through gateways,
  handles tool calling with automatic recursion, and provides a clean
  API for text and structured output generation.

  ## Examples

      # Create a broker with Ollama
      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.Ollama

      broker = Broker.new("llama3.2", Ollama)

      # Generate a simple response
      messages = [Message.user("What is 2+2?")]
      {:ok, response} = Broker.generate(broker, messages)

      # Generate structured output
      schema = %{
        type: "object",
        properties: %{answer: %{type: "number"}},
        required: ["answer"]
      }
      {:ok, result} = Broker.generate_object(broker, messages, schema)

  ## Tool Support

  The broker automatically handles tool calls from the LLM. When the LLM
  requests a tool call, the broker will:

  1. Execute the tool with the provided arguments
  2. Add the tool result to the conversation
  3. Recursively call the LLM to generate the final response

  Example with tools:

      tools = [MyTool]
      {:ok, response} = Broker.generate(broker, messages, tools)

  """

  require Logger

  alias Mojentic.LLM.{
    Gateway,
    Message,
    CompletionConfig
  }

  alias Mojentic.LLM.Tools.Tool

  @type t :: %__MODULE__{
          model: String.t(),
          gateway: Gateway.gateway()
        }

  defstruct [:model, :gateway]

  @doc """
  Creates a new LLM broker.

  ## Parameters

  - `model`: Model identifier (e.g., "llama3.2", "gpt-4")
  - `gateway`: Gateway module (e.g., `Mojentic.LLM.Gateways.Ollama`)

  ## Examples

      iex> Broker.new("llama3.2", Mojentic.LLM.Gateways.Ollama)
      %Broker{model: "llama3.2", gateway: Mojentic.LLM.Gateways.Ollama}

  """
  def new(model, gateway) do
    %__MODULE__{
      model: model,
      gateway: gateway
    }
  end

  @doc """
  Generates text response from the LLM.

  Handles tool calls automatically through recursion. When the LLM
  requests a tool call, the broker executes the tool and continues
  the conversation with the result.

  ## Parameters

  - `broker`: Broker instance
  - `messages`: List of conversation messages
  - `tools`: Optional list of tool modules (default: nil)
  - `config`: Optional completion configuration (default: default config)

  ## Returns

  - `{:ok, response_text}` on success
  - `{:error, reason}` on failure

  ## Examples

      broker = Broker.new("llama3.2", Ollama)
      messages = [Message.user("What is the capital of France?")]

      {:ok, response} = Broker.generate(broker, messages)
      # => {:ok, "The capital of France is Paris."}

      # With tools
      tools = [WeatherTool]
      messages = [Message.user("What's the weather in SF?")]
      {:ok, response} = Broker.generate(broker, messages, tools)

  """
  def generate(broker, messages, tools \\ nil, config \\ nil) do
    config = config || %CompletionConfig{}

    with {:ok, response} <-
           broker.gateway.complete(
             broker.model,
             messages,
             tools,
             config
           ) do
      case response.tool_calls do
        [] ->
          {:ok, response.content || ""}

        _tool_calls ->
          handle_tool_calls(
            broker,
            messages,
            response,
            tools,
            config
          )
      end
    end
  end

  @doc """
  Generates structured object response from the LLM.

  Uses JSON schema to enforce the structure of the response. The LLM
  will return a JSON object conforming to the provided schema.

  ## Parameters

  - `broker`: Broker instance
  - `messages`: List of conversation messages
  - `schema`: JSON schema for the expected response structure
  - `config`: Optional completion configuration (default: default config)

  ## Returns

  - `{:ok, parsed_object}` map conforming to schema on success
  - `{:error, reason}` on failure

  ## Examples

      broker = Broker.new("llama3.2", Ollama)

      schema = %{
        type: "object",
        properties: %{
          sentiment: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["sentiment", "confidence"]
      }

      messages = [Message.user("I love this!")]
      {:ok, result} = Broker.generate_object(broker, messages, schema)
      # => {:ok, %{"sentiment" => "positive", "confidence" => 0.95}}

  """
  def generate_object(broker, messages, schema, config \\ nil) do
    config = config || %CompletionConfig{}

    with {:ok, response} <-
           broker.gateway.complete_object(
             broker.model,
             messages,
             schema,
             config
           ) do
      case response.object do
        nil -> {:error, :no_object_in_response}
        object -> {:ok, object}
      end
    end
  end

  # Private functions

  defp handle_tool_calls(broker, messages, response, tools, config) do
    case tools do
      nil ->
        Logger.warning("LLM requested tool calls but no tools provided")
        {:ok, response.content || ""}

      [] ->
        Logger.warning("LLM requested tool calls but no tools provided")
        {:ok, response.content || ""}

      tools ->
        Logger.info("Processing #{length(response.tool_calls)} tool call(s)")

        # Add assistant message with tool calls
        new_messages = messages ++ [build_assistant_message(response)]

        # Execute all tool calls
        tool_results =
          Enum.map(response.tool_calls, fn tool_call ->
            execute_tool(tool_call, tools)
          end)

        # Add tool result messages
        final_messages =
          Enum.reduce(tool_results, new_messages, fn
            {:ok, tool_message}, acc -> acc ++ [tool_message]
            {:error, reason}, acc ->
              Logger.error("Tool execution failed: #{inspect(reason)}")
              acc
          end)

        # Recursively call generate with updated messages
        generate(broker, final_messages, tools, config)
    end
  end

  defp build_assistant_message(response) do
    %Message{
      role: :assistant,
      content: response.content,
      tool_calls: response.tool_calls
    }
  end

  defp execute_tool(tool_call, tools) do
    case find_tool(tools, tool_call.name) do
      nil ->
        Logger.warning("Tool not found: #{tool_call.name}")
        {:error, {:tool_not_found, tool_call.name}}

      tool ->
        Logger.info("Executing tool: #{tool_call.name}")

        case Tool.run(tool, tool_call.arguments) do
          {:ok, result} ->
            {:ok,
             %Message{
               role: :tool,
               content: Jason.encode!(result),
               tool_calls: [tool_call]
             }}

          {:error, reason} ->
            Logger.error("Tool execution failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn tool ->
      Tool.matches?(tool, name)
    end)
  end
end
