defmodule Mojentic.LLM.CompletionConfig do
  @moduledoc """
  Configuration for LLM completion requests.

  Provides settings for temperature, context window size, and token limits.

  ## Examples

      iex> CompletionConfig.new()
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: nil, top_k: nil, response_format: nil, reasoning_effort: nil}

      iex> CompletionConfig.new(temperature: 0.7, max_tokens: 1000)
      %CompletionConfig{temperature: 0.7, num_ctx: 32768, max_tokens: 1000, top_p: nil, top_k: nil, response_format: nil, reasoning_effort: nil}

      iex> CompletionConfig.new(top_p: 0.9, top_k: 40)
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: 0.9, top_k: 40, response_format: nil, reasoning_effort: nil}

  """

  @type response_format :: %{
          type: :json_object | :text,
          schema: map() | nil
        }

  @type reasoning_effort :: :low | :medium | :high

  @type t :: %__MODULE__{
          temperature: float(),
          num_ctx: pos_integer(),
          max_tokens: pos_integer(),
          num_predict: integer() | nil,
          top_p: float() | nil,
          top_k: integer() | nil,
          response_format: response_format() | nil,
          reasoning_effort: reasoning_effort() | nil
        }

  defstruct temperature: 1.0,
            num_ctx: 32_768,
            max_tokens: 16_384,
            num_predict: nil,
            top_p: nil,
            top_k: nil,
            response_format: nil,
            reasoning_effort: nil

  @doc """
  Creates a new configuration with optional overrides.

  ## Parameters

  - `opts`: Keyword list of options to override defaults

  ## Examples

      iex> CompletionConfig.new(temperature: 0.5)
      %CompletionConfig{temperature: 0.5, num_ctx: 32768, max_tokens: 16384, top_p: nil, top_k: nil, response_format: nil, reasoning_effort: nil}

      iex> CompletionConfig.new(top_p: 0.95)
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: 0.95, top_k: nil, response_format: nil, reasoning_effort: nil}

      iex> CompletionConfig.new(response_format: %{type: :json_object, schema: nil})
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384, top_p: nil, top_k: nil, response_format: %{type: :json_object, schema: nil}, reasoning_effort: nil}

  """
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
