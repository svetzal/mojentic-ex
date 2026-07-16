defmodule Mojentic.TestSupport.StubTokenizer do
  @moduledoc false
  # A lightweight tokenizer stub for use in tests. It splits on whitespace to
  # produce token IDs so that counts are proportional to text length without
  # making any network requests.

  @behaviour Mojentic.LLM.Tokenizer

  defstruct []

  @doc "Creates a new stub tokenizer instance."
  @spec new!() :: %__MODULE__{}
  def new!, do: %__MODULE__{}

  @impl Mojentic.LLM.Tokenizer
  @spec encode(%__MODULE__{}, String.t()) :: [integer()]
  def encode(%__MODULE__{}, ""), do: []

  def encode(%__MODULE__{}, text) do
    text
    |> String.split()
    |> Enum.with_index()
    |> Enum.map(fn {_word, idx} -> idx end)
  end

  @impl Mojentic.LLM.Tokenizer
  @spec decode(%__MODULE__{}, [integer()]) :: String.t()
  def decode(%__MODULE__{}, tokens),
    do: Enum.map_join(tokens, " ", &Integer.to_string/1)

  @impl Mojentic.LLM.Tokenizer
  @spec count_tokens(%__MODULE__{}, String.t()) :: non_neg_integer()
  def count_tokens(%__MODULE__{} = tokenizer, text), do: tokenizer |> encode(text) |> length()
end
