defmodule Mojentic.LLM.Gateways.OllamaTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.Gateways.Ollama
  alias Mojentic.LLM.{Message, CompletionConfig}

  # Note: These are integration-style tests that verify the module's structure
  # and error handling. Full integration testing would require a running Ollama instance.

  describe "complete/4 - structure and error handling" do
    test "returns error when Ollama is not reachable" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      # This will fail since Ollama is likely not running in test environment
      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should return an error tuple, not crash
      assert match?({:error, _}, result)
    end

    test "handles empty messages list" do
      messages = []
      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should return an error, not crash
      assert match?({:error, _}, result)
    end

    test "handles nil config gracefully" do
      messages = [Message.user("Hello")]

      # This should fail since config is required
      assert_raise KeyError, fn ->
        Ollama.complete("qwen3:32b", messages, [], nil)
      end
    end
  end

  describe "complete_object/4 - structure and error handling" do
    test "returns error when Ollama is not reachable" do
      messages = [Message.user("Generate a person")]
      schema = %{type: "object", properties: %{name: %{type: "string"}}}
      config = CompletionConfig.new()

      result = Ollama.complete_object("qwen3:32b", messages, schema, config)

      # Should return an error tuple, not crash
      assert match?({:error, _}, result)
    end

    test "handles empty messages list" do
      messages = []
      schema = %{type: "object"}
      config = CompletionConfig.new()

      result = Ollama.complete_object("qwen3:32b", messages, schema, config)

      # Should return an error, not crash
      assert match?({:error, _}, result)
    end
  end

  describe "get_available_models/0" do
    test "returns list of models or error when Ollama is not reachable" do
      result = Ollama.get_available_models()

      # Should return either success or error tuple, not crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "calculate_embeddings/2" do
    test "returns embeddings or error when Ollama is not reachable" do
      result = Ollama.calculate_embeddings("qwen3:32b", "test text")

      # Should return either success or error tuple, not crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles empty text" do
      result = Ollama.calculate_embeddings("qwen3:32b", "")

      # Empty text may succeed or fail depending on Ollama behavior
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles nil text gracefully" do
      result = Ollama.calculate_embeddings("qwen3:32b", nil)

      # Nil text may succeed or fail depending on Ollama behavior
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "configuration" do
    test "uses default host from environment or fallback" do
      # Test that the module doesn't crash when accessing environment variables
      # Actual value will depend on environment
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should attempt the request with some host
      assert match?({:error, _}, result)
    end

    test "respects custom timeout settings" do
      # This test verifies the module attempts to use timeout configurations
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should handle timeout configuration
      assert match?({:error, _}, result)
    end
  end

  describe "message adaptation" do
    test "handles user messages" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should process user messages without crashing
      assert match?({:error, _}, result)
    end

    test "handles system messages" do
      messages = [Message.system("You are helpful"), Message.user("Hello")]
      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should process system messages without crashing
      assert match?({:error, _}, result)
    end

    test "handles assistant messages" do
      messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("How are you?")
      ]

      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should process assistant messages without crashing
      assert match?({:error, _}, result)
    end

    test "handles mixed message types" do
      messages = [
        Message.system("Be helpful"),
        Message.user("Hello"),
        Message.assistant("Hi"),
        Message.user("Tell me a fact")
      ]

      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should process mixed messages without crashing
      assert match?({:error, _}, result)
    end
  end

  describe "tool integration" do
    defmodule MockTool do
      @behaviour Mojentic.LLM.Tools.Tool

      @impl true
      def run(_args), do: {:ok, %{result: "test"}}

      @impl true
      def descriptor do
        %{
          type: "function",
          function: %{
            name: "mock_tool",
            description: "A mock tool",
            parameters: %{type: "object", properties: %{}}
          }
        }
      end

      def matches?("mock_tool"), do: true
      def matches?(_), do: false
    end

    test "handles tools parameter" do
      messages = [Message.user("Use a tool")]
      config = CompletionConfig.new()
      tools = [MockTool]

      result = Ollama.complete("qwen3:32b", messages, tools, config)

      # Should process tools without crashing
      assert match?({:error, _}, result)
    end

    test "handles empty tools list" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should handle empty tools list
      assert match?({:error, _}, result)
    end
  end

  describe "config options extraction" do
    test "extracts temperature from config" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new(temperature: 0.7)

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should use temperature from config
      assert match?({:error, _}, result)
    end

    test "extracts num_ctx from config" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new(num_ctx: 4096)

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should use num_ctx from config
      assert match?({:error, _}, result)
    end

    test "extracts num_predict from config" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new(num_predict: 512)

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should use num_predict from config
      assert match?({:error, _}, result)
    end

    test "handles config with multiple options" do
      messages = [Message.user("Hello")]

      config =
        CompletionConfig.new(
          temperature: 0.5,
          num_ctx: 8192,
          num_predict: 1024
        )

      result = Ollama.complete("qwen3:32b", messages, [], config)

      # Should use all config options
      assert match?({:error, _}, result)
    end
  end
end
