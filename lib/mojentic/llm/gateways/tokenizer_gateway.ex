defmodule Mojentic.LLM.Gateways.TokenizerGateway do
  @moduledoc """
  Gateway for tokenizing and detokenizing text using Hugging Face tokenizers.

  This gateway provides encoding and decoding functionality for text,
  which is useful for:
  - Counting tokens to manage context windows
  - Understanding token usage for cost estimation
  - Debugging token-related issues

  The gateway uses the `tokenizers` library, which provides Rust-based
  tokenizers via Rustler NIF bindings for high performance.

  ## Examples

      iex> {:ok, tokenizer} = Mojentic.LLM.Gateways.TokenizerGateway.new()
      iex> tokens = Mojentic.LLM.Gateways.TokenizerGateway.encode(tokenizer, "Hello, world!")
      iex> text = Mojentic.LLM.Gateways.TokenizerGateway.decode(tokenizer, tokens)
      iex> text
      "Hello, world!"

  """

  require Logger

  @type t :: %__MODULE__{
          tokenizer: Tokenizers.Tokenizer.t()
        }

  defstruct [:tokenizer]

  @doc """
  Creates a new TokenizerGateway with the specified model.

  ## Parameters

    * `model` - The model name to load. Defaults to "gpt2" which uses a BPE tokenizer
      similar to GPT models. Other options include model identifiers from Hugging Face.

  ## Returns

    * `{:ok, gateway}` - Successfully created gateway
    * `{:error, reason}` - Failed to load tokenizer

  ## Examples

      iex> {:ok, tokenizer} = Mojentic.LLM.Gateways.TokenizerGateway.new()
      iex> is_struct(tokenizer, Mojentic.LLM.Gateways.TokenizerGateway)
      true

      iex> {:ok, tokenizer} = Mojentic.LLM.Gateways.TokenizerGateway.new("bert-base-uncased")
      iex> is_struct(tokenizer, Mojentic.LLM.Gateways.TokenizerGateway)
      true

  """
  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(model \\ "gpt2") do
    Logger.debug("Loading tokenizer for model: #{model}")

    case Tokenizers.Tokenizer.from_pretrained(model) do
      {:ok, tokenizer} ->
        {:ok, %__MODULE__{tokenizer: tokenizer}}

      {:error, reason} ->
        Logger.error("Failed to load tokenizer: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Creates a new TokenizerGateway with the specified model, raising on error.

  ## Parameters

    * `model` - The model name to load. Defaults to "gpt2".

  ## Returns

    * `gateway` - Successfully created gateway

  ## Raises

    * `RuntimeError` - If the tokenizer fails to load

  ## Examples

      iex> tokenizer = Mojentic.LLM.Gateways.TokenizerGateway.new!()
      iex> is_struct(tokenizer, Mojentic.LLM.Gateways.TokenizerGateway)
      true

  """
  @spec new!(String.t()) :: t()
  def new!(model \\ "gpt2") do
    case new(model) do
      {:ok, gateway} -> gateway
      {:error, reason} -> raise "Failed to create TokenizerGateway: #{inspect(reason)}"
    end
  end

  @doc """
  Encodes text into tokens.

  ## Parameters

    * `gateway` - The TokenizerGateway instance
    * `text` - The text to encode

  ## Returns

    * `tokens` - List of token IDs

  ## Examples

      iex> {:ok, tokenizer} = Mojentic.LLM.Gateways.TokenizerGateway.new()
      iex> tokens = Mojentic.LLM.Gateways.TokenizerGateway.encode(tokenizer, "Hello, world!")
      iex> is_list(tokens) and length(tokens) > 0
      true

  """
  @spec encode(t(), String.t()) :: list(integer())
  def encode(%__MODULE__{tokenizer: tokenizer}, text) do
    Logger.debug("Encoding text: #{text}")

    case Tokenizers.Tokenizer.encode(tokenizer, text) do
      {:ok, encoding} ->
        Tokenizers.Encoding.get_ids(encoding)

      {:error, reason} ->
        Logger.error("Failed to encode text: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Decodes tokens back into text.

  ## Parameters

    * `gateway` - The TokenizerGateway instance
    * `tokens` - List of token IDs to decode

  ## Returns

    * `text` - The decoded text

  ## Examples

      iex> {:ok, tokenizer} = Mojentic.LLM.Gateways.TokenizerGateway.new()
      iex> tokens = Mojentic.LLM.Gateways.TokenizerGateway.encode(tokenizer, "Hello!")
      iex> text = Mojentic.LLM.Gateways.TokenizerGateway.decode(tokenizer, tokens)
      iex> text
      "Hello!"

  """
  @spec decode(t(), list(integer())) :: String.t()
  def decode(%__MODULE__{tokenizer: tokenizer}, tokens) do
    Logger.debug("Decoding #{length(tokens)} tokens")

    case Tokenizers.Tokenizer.decode(tokenizer, tokens) do
      {:ok, text} ->
        text

      {:error, reason} ->
        Logger.error("Failed to decode tokens: #{inspect(reason)}")
        ""
    end
  end

  @doc """
  Counts the number of tokens in a text string.

  This is a convenience function that encodes the text and returns
  the token count.

  ## Parameters

    * `gateway` - The TokenizerGateway instance
    * `text` - The text to count tokens for

  ## Returns

    * `count` - The number of tokens

  ## Examples

      iex> {:ok, tokenizer} = Mojentic.LLM.Gateways.TokenizerGateway.new()
      iex> count = Mojentic.LLM.Gateways.TokenizerGateway.count_tokens(tokenizer, "Hello, world!")
      iex> count > 0
      true

  """
  @spec count_tokens(t(), String.t()) :: non_neg_integer()
  def count_tokens(gateway, text) do
    gateway
    |> encode(text)
    |> length()
  end
end
