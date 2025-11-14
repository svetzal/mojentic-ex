defmodule Mojentic.LLM.Gateway do
  @moduledoc """
  Behaviour for LLM gateway implementations.

  A gateway handles communication with a specific LLM provider,
  converting between the universal message format and the
  provider-specific API.

  ## Examples

  Implementing a custom gateway:

      defmodule MyGateway do
        @behaviour Mojentic.LLM.Gateway

        @impl true
        def complete(model, messages, tools, config) do
          # Implementation here
          {:ok, %GatewayResponse{content: "response"}}
        end

        @impl true
        def complete_object(model, messages, schema, config) do
          # Implementation here
          {:ok, %GatewayResponse{object: %{}}}
        end

        @impl true
        def get_available_models do
          {:ok, ["model1", "model2"]}
        end

        @impl true
        def calculate_embeddings(text, model) do
          {:ok, [0.1, 0.2, 0.3]}
        end
      end

  """

  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Message

  @type gateway :: module()
  @type error :: {:error, atom() | String.t() | {atom(), term()}}

  @doc """
  Completes an LLM request with text response.

  ## Parameters

  - `model`: Model identifier (e.g., "gpt-4", "qwen3:32b")
  - `messages`: List of conversation messages
  - `tools`: Optional list of available tool modules
  - `config`: Completion configuration

  ## Returns

  - `{:ok, response}` on success
  - `{:error, reason}` on failure

  """
  @callback complete(
              model :: String.t(),
              messages :: [Message.t()],
              tools :: [module()] | nil,
              config :: CompletionConfig.t()
            ) :: {:ok, GatewayResponse.t()} | error()

  @doc """
  Completes an LLM request with structured object response.

  The response will be parsed into a map based on the provided schema.

  ## Parameters

  - `model`: Model identifier
  - `messages`: List of conversation messages
  - `schema`: JSON schema defining the expected structure
  - `config`: Completion configuration

  ## Returns

  - `{:ok, response}` with parsed object on success
  - `{:error, reason}` on failure

  """
  @callback complete_object(
              model :: String.t(),
              messages :: [Message.t()],
              schema :: map(),
              config :: CompletionConfig.t()
            ) :: {:ok, GatewayResponse.t()} | error()

  @doc """
  Gets list of available models from the provider.

  ## Returns

  - `{:ok, models}` list of model names
  - `{:error, reason}` on failure

  """
  @callback get_available_models() :: {:ok, [String.t()]} | error()

  @doc """
  Calculates embeddings for the given text.

  ## Parameters

  - `text`: Text to generate embeddings for
  - `model`: Optional model identifier for embeddings

  ## Returns

  - `{:ok, embeddings}` vector of floats
  - `{:error, reason}` on failure

  """
  @callback calculate_embeddings(
              text :: String.t(),
              model :: String.t() | nil
            ) :: {:ok, [float()]} | error()

  @doc """
  Streams LLM responses chunk by chunk.

  Returns a stream that yields response chunks as they arrive. Tool calls
  will be accumulated and yielded when complete.

  ## Parameters

  - `model`: Model identifier
  - `messages`: List of conversation messages
  - `tools`: Optional list of available tool modules
  - `config`: Completion configuration

  ## Returns

  A stream of `{:content, chunk}` or `{:tool_calls, calls}` tuples

  """
  @callback complete_stream(
              model :: String.t(),
              messages :: [Message.t()],
              tools :: [module()] | nil,
              config :: CompletionConfig.t()
            ) :: Enumerable.t()
end
