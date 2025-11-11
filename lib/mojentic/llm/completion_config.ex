defmodule Mojentic.LLM.CompletionConfig do
  @moduledoc """
  Configuration for LLM completion requests.

  Provides settings for temperature, context window size, and token limits.

  ## Examples

      iex> CompletionConfig.new()
      %CompletionConfig{temperature: 1.0, num_ctx: 32768, max_tokens: 16384}

      iex> CompletionConfig.new(temperature: 0.7, max_tokens: 1000)
      %CompletionConfig{temperature: 0.7, num_ctx: 32768, max_tokens: 1000}

  """

  @type t :: %__MODULE__{
          temperature: float(),
          num_ctx: pos_integer(),
          max_tokens: pos_integer(),
          num_predict: integer() | nil
        }

  defstruct temperature: 1.0,
            num_ctx: 32768,
            max_tokens: 16384,
            num_predict: nil

  @doc """
  Creates a new configuration with optional overrides.

  ## Parameters

  - `opts`: Keyword list of options to override defaults

  ## Examples

      iex> CompletionConfig.new(temperature: 0.5)
      %CompletionConfig{temperature: 0.5, num_ctx: 32768, max_tokens: 16384}

  """
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
