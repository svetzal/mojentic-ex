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
  @type error ::
          {:error, Mojentic.LLM.CompletionError.t() | atom() | String.t() | {atom(), term()}}

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
  Returns the advertised context window and field provenance, or `{:ok, nil}`.
  Optional for custom gateways. Use `get_model_context_window/2` for compatible dispatch.
  Discovery never changes later completion requests.
  """
  @callback get_model_context_window(String.t()) ::
              {:ok, Mojentic.LLM.ModelContextWindow.t() | nil} | error()
  @optional_callbacks get_model_context_window: 1

  @doc "Queries a gateway, treating implementations without metadata support as not advertised."
  @spec get_model_context_window(module(), String.t()) ::
          {:ok, Mojentic.LLM.ModelContextWindow.t() | nil} | error()
  def get_model_context_window(gateway, model) do
    if Code.ensure_loaded?(gateway) and function_exported?(gateway, :get_model_context_window, 1),
      do: gateway.get_model_context_window(model),
      else: {:ok, nil}
  end

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

  A stream of `{:content, chunk}`, `{:thinking, text}`, `{:tool_calls, calls}`
  and `{:completed, evidence}` tuples. Terminal `evidence.metadata` carries
  client `request_duration_ms` and, when a token arrived, `time_to_first_token_ms`
  and `first_token_kind` (`:thinking`, `:content` or `:tool_call`). Thinking wins
  ties within a frame, then content, then nonempty tool arguments. Measurements
  start at HTTP dispatch, span admitted retries and reset for tool continuations.
  Capture must succeed before observed output can be delivered.
  Stream errors carry the same measurements: `CompletionError.metadata` with
  recovery, existing error evidence where available, otherwise
  `{:stream_error, original_reason, %{metadata: metrics}}`.

  """
  @callback complete_stream(
              model :: String.t(),
              messages :: [Message.t()],
              tools :: [module()] | nil,
              config :: CompletionConfig.t()
            ) :: Enumerable.t()
  @doc """
  Single-turn content and terminal events. No executable tools are supplied.

  Terminal metadata has the same client timing contract as `complete_stream/4`.
  Provider usage and durations retain their original fields and units.
  """
  @callback complete_stream_events(String.t(), [Message.t()], CompletionConfig.t()) ::
              Enumerable.t()
  @optional_callbacks complete_stream_events: 3
end
