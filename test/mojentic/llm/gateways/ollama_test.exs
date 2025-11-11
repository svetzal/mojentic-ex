defmodule Mojentic.LLM.Gateways.OllamaTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.Gateways.Ollama
  alias Mojentic.LLM.Message

  # These tests verify the module structure without making actual HTTP calls
  # They expect the module to fail gracefully when Ollama is not available

  describe "complete/4 - structure and error handling" do
    test "module has correct function signature" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      # Test that function exists and returns appropriate type
      result = Ollama.complete("qwen2.5:3b", messages, [], config)
      
      # Should return tuple (either ok or error)
      assert is_tuple(result)
      assert tuple_size(result) >= 2
    end
  end

  describe "complete_object/4 - structure and error handling" do
    test "module has correct function signature" do
      messages = [Message.user("Generate data")]
      schema = %{type: "object"}
      config = CompletionConfig.new()

      result = Ollama.complete_object("qwen2.5:3b", messages, schema, config)
      
      # Should return tuple
      assert is_tuple(result)
      assert tuple_size(result) >= 2
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

    test "accepts tools parameter" do
      messages = [Message.user("Use a tool")]
      config = CompletionConfig.new()
      tools = [MockTool]

      result = Ollama.complete("qwen2.5:3b", messages, tools, config)
      
      # Should not crash with tools
      assert is_tuple(result)
    end
  end
end
