defmodule Mojentic.LLM.Gateways.TokenizerGatewayTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Gateways.TokenizerGateway

  describe "new/1" do
    test "creates gateway with default model" do
      assert {:ok, %TokenizerGateway{}} = TokenizerGateway.new()
    end

    test "creates gateway with specified model" do
      assert {:ok, %TokenizerGateway{}} = TokenizerGateway.new("gpt2")
    end

    test "returns error for invalid model" do
      assert {:error, _reason} = TokenizerGateway.new("nonexistent-model-xyz")
    end
  end

  describe "new!/1" do
    test "creates gateway with default model" do
      assert %TokenizerGateway{} = TokenizerGateway.new!()
    end

    test "raises on invalid model" do
      assert_raise RuntimeError, fn ->
        TokenizerGateway.new!("nonexistent-model-xyz")
      end
    end
  end

  describe "encode/2" do
    setup do
      {:ok, tokenizer} = TokenizerGateway.new()
      {:ok, tokenizer: tokenizer}
    end

    test "encodes text into tokens", %{tokenizer: tokenizer} do
      tokens = TokenizerGateway.encode(tokenizer, "Hello, world!")

      assert is_list(tokens)
      assert length(tokens) > 0
      assert Enum.all?(tokens, &is_integer/1)
    end

    test "encodes empty string", %{tokenizer: tokenizer} do
      tokens = TokenizerGateway.encode(tokenizer, "")
      assert tokens == []
    end

    test "produces consistent encodings", %{tokenizer: tokenizer} do
      text = "The quick brown fox"
      tokens1 = TokenizerGateway.encode(tokenizer, text)
      tokens2 = TokenizerGateway.encode(tokenizer, text)

      assert tokens1 == tokens2
    end
  end

  describe "decode/2" do
    setup do
      {:ok, tokenizer} = TokenizerGateway.new()
      {:ok, tokenizer: tokenizer}
    end

    test "decodes tokens back to text", %{tokenizer: tokenizer} do
      original = "Hello, world!"
      tokens = TokenizerGateway.encode(tokenizer, original)
      decoded = TokenizerGateway.decode(tokenizer, tokens)

      assert decoded == original
    end

    test "decodes empty token list", %{tokenizer: tokenizer} do
      text = TokenizerGateway.decode(tokenizer, [])
      assert text == ""
    end

    test "round-trips text correctly", %{tokenizer: tokenizer} do
      test_cases = [
        "Simple text",
        "Text with numbers: 123456",
        "Special characters: !@#$%^&*()",
        "Multi-line\ntext\nwith\nnewlines",
        "Unicode: 你好世界 🌍"
      ]

      for original <- test_cases do
        tokens = TokenizerGateway.encode(tokenizer, original)
        decoded = TokenizerGateway.decode(tokenizer, tokens)
        assert decoded == original, "Round-trip failed for: #{original}"
      end
    end
  end

  describe "count_tokens/2" do
    setup do
      {:ok, tokenizer} = TokenizerGateway.new()
      {:ok, tokenizer: tokenizer}
    end

    test "counts tokens for text", %{tokenizer: tokenizer} do
      text = "What is the capital of France?"
      count = TokenizerGateway.count_tokens(tokenizer, text)

      assert is_integer(count)
      assert count > 0
    end

    test "count matches encode length", %{tokenizer: tokenizer} do
      text = "The quick brown fox jumps over the lazy dog."
      tokens = TokenizerGateway.encode(tokenizer, text)
      count = TokenizerGateway.count_tokens(tokenizer, text)

      assert length(tokens) == count
    end

    test "counts zero for empty string", %{tokenizer: tokenizer} do
      count = TokenizerGateway.count_tokens(tokenizer, "")
      assert count == 0
    end

    test "handles long text", %{tokenizer: tokenizer} do
      long_text = String.duplicate("word ", 1000)
      count = TokenizerGateway.count_tokens(tokenizer, long_text)

      assert count > 1000
    end
  end

  describe "different models" do
    test "gpt2 model works" do
      {:ok, tokenizer} = TokenizerGateway.new("gpt2")
      text = "Hello, world!"
      tokens = TokenizerGateway.encode(tokenizer, text)

      assert length(tokens) > 0
      assert TokenizerGateway.decode(tokenizer, tokens) == text
    end

    test "bert-base-uncased model works" do
      {:ok, tokenizer} = TokenizerGateway.new("bert-base-uncased")
      text = "Hello, world!"
      tokens = TokenizerGateway.encode(tokenizer, text)

      assert length(tokens) > 0
      # BERT may alter casing and add special tokens
      decoded = TokenizerGateway.decode(tokenizer, tokens)
      assert is_binary(decoded)
    end
  end

  describe "unicode handling" do
    setup do
      {:ok, tokenizer} = TokenizerGateway.new()
      {:ok, tokenizer: tokenizer}
    end

    test "handles unicode text", %{tokenizer: tokenizer} do
      unicode_text = "Hello 世界! 🌍 Special chars: @#$%"
      tokens = TokenizerGateway.encode(tokenizer, unicode_text)
      decoded = TokenizerGateway.decode(tokenizer, tokens)

      assert decoded == unicode_text
      assert length(tokens) > 0
    end

    test "handles emoji", %{tokenizer: tokenizer} do
      emoji_text = "Hello 👋 World 🌍"
      tokens = TokenizerGateway.encode(tokenizer, emoji_text)
      decoded = TokenizerGateway.decode(tokenizer, tokens)

      assert decoded == emoji_text
    end
  end
end
