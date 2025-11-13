#!/usr/bin/env elixir

# Example demonstrating the TokenizerGateway usage.
#
# This shows how to:
# - Create a tokenizer instance
# - Encode text into tokens
# - Decode tokens back to text
# - Count tokens for context window management

Mix.install([
  {:mojentic, path: "."}
])

alias Mojentic.LLM.Gateways.TokenizerGateway

defmodule TokenizerExample do
  def run do
    # Create a tokenizer with the default gpt2 model
    {:ok, tokenizer} = TokenizerGateway.new()

    IO.puts("=== TokenizerGateway Example ===\n")

    # Example 1: Basic encoding and decoding
    text1 = "Hello, world! This is a test message."
    IO.puts(~s(Original text: "#{text1}"))

    tokens1 = TokenizerGateway.encode(tokenizer, text1)
    IO.puts("Tokens: #{inspect(tokens1)}")
    IO.puts("Token count: #{length(tokens1)}")

    decoded1 = TokenizerGateway.decode(tokenizer, tokens1)
    IO.puts(~s(Decoded text: "#{decoded1}"))
    IO.puts("Round-trip successful: #{text1 == decoded1}\n")

    # Example 2: Counting tokens for context window management
    long_message = """
    This is a longer message that demonstrates token counting.
    Token counting is important for:
    - Managing context window limits
    - Estimating API costs
    - Optimizing prompt engineering
    - Debugging tokenization issues
    """
    |> String.trim()

    tokens2 = TokenizerGateway.encode(tokenizer, long_message)
    IO.puts("\nLong message token count: #{length(tokens2)}")
    IO.puts("First 10 tokens: #{inspect(Enum.take(tokens2, 10))}")

    # Example 3: Comparing different text lengths
    texts = [
      "Hi",
      "Hello, how are you?",
      "The quick brown fox jumps over the lazy dog.",
      "A much longer sentence with more words will naturally have more tokens."
    ]

    IO.puts("\n=== Token Counts for Different Text Lengths ===")

    for text <- texts do
      tokens = TokenizerGateway.encode(tokenizer, text)
      IO.puts(~s("#{text}"))
      IO.puts("  → #{length(tokens)} tokens\n")
    end

    # Example 4: Unicode and special characters
    unicode_text = "Hello 世界! 🌍 Special chars: @#$%"
    unicode_tokens = TokenizerGateway.encode(tokenizer, unicode_text)
    IO.puts(~s(Unicode text: "#{unicode_text}"))
    IO.puts("Token count: #{length(unicode_tokens)}")
    IO.puts(~s(Decoded: "#{TokenizerGateway.decode(tokenizer, unicode_tokens)}"\n))

    # Example 5: Using count_tokens convenience method
    sample_text = "What is the capital of France?"
    count = TokenizerGateway.count_tokens(tokenizer, sample_text)
    IO.puts(~s(Token count for "#{sample_text}": #{count}))

    # Example 6: Different models
    IO.puts("\n=== Different Models ===")

    {:ok, tokenizer_gpt2} = TokenizerGateway.new("gpt2")
    count_gpt2 = TokenizerGateway.count_tokens(tokenizer_gpt2, "This is a test")

    {:ok, tokenizer_bert} = TokenizerGateway.new("bert-base-uncased")
    count_bert = TokenizerGateway.count_tokens(tokenizer_bert, "This is a test")

    IO.puts("gpt2: #{count_gpt2} tokens")
    IO.puts("bert-base-uncased: #{count_bert} tokens")

    IO.puts("\nTokenizer example completed!")
  end
end

TokenizerExample.run()
