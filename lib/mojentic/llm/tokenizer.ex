defmodule Mojentic.LLM.Tokenizer do
  @moduledoc """
  Behaviour for text tokenization implementations.

  Implement this behaviour to provide a custom tokenizer for use with
  `Mojentic.LLM.ChatSession` and other components that require token counting.

  The default implementation is `Mojentic.LLM.Gateways.TokenizerGateway`, which
  downloads and uses Hugging Face tokenizers. You can override the default by
  setting `Application.put_env(:mojentic, :default_tokenizer_mod, MyTokenizer)`.

  ## Example

      defmodule MyTokenizer do
        @behaviour Mojentic.LLM.Tokenizer

        defstruct []

        def new!, do: %__MODULE__{}

        @impl true
        def encode(%__MODULE__{}, text), do: String.split(text)

        @impl true
        def decode(%__MODULE__{}, tokens), do: Enum.join(tokens, " ")

        @impl true
        def count_tokens(tokenizer, text), do: tokenizer |> encode(text) |> length()
      end

  """

  @type t :: struct()

  @doc """
  Encodes text into a list of token IDs.
  """
  @callback encode(tokenizer :: t(), text :: String.t()) :: [integer()]

  @doc """
  Decodes a list of token IDs back into text.
  """
  @callback decode(tokenizer :: t(), tokens :: [integer()]) :: String.t()

  @doc """
  Counts the number of tokens in a text string.
  """
  @callback count_tokens(tokenizer :: t(), text :: String.t()) :: non_neg_integer()
end
