defmodule Mojentic.LLM.Gateways.OpenAIModelRegistryTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Gateways.OpenAIModelRegistry

  describe "new/0" do
    test "creates a new registry with models" do
      registry = OpenAIModelRegistry.new()
      assert length(OpenAIModelRegistry.get_registered_models(registry)) > 0
    end
  end

  describe "get_model_capabilities/2" do
    test "returns capabilities for known chat model" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4")

      assert caps.model_type == :chat
      assert caps.supports_tools == true
    end

    test "returns capabilities for known reasoning model" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "o1")

      assert caps.model_type == :reasoning
      assert caps.supports_tools == true
      assert caps.supports_streaming == true
    end

    test "returns capabilities for known embedding model" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "text-embedding-3-large")

      assert caps.model_type == :embedding
      assert caps.supports_tools == false
      assert caps.supports_streaming == false
    end

    test "uses pattern matching for unknown gpt-4 variant" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4-unknown-variant")

      assert caps.model_type == :chat
    end

    test "uses pattern matching for unknown o1 variant" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "o1-custom")

      assert caps.model_type == :reasoning
    end

    test "defaults to chat for completely unknown model" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "completely-unknown")

      assert caps.model_type == :chat
    end
  end

  describe "get_token_limit_param/2" do
    test "returns max_completion_tokens for reasoning models" do
      registry = OpenAIModelRegistry.new()
      param = OpenAIModelRegistry.get_token_limit_param(registry, "o1")

      assert param == "max_completion_tokens"
    end

    test "returns max_tokens for chat models" do
      registry = OpenAIModelRegistry.new()
      param = OpenAIModelRegistry.get_token_limit_param(registry, "gpt-4")

      assert param == "max_tokens"
    end
  end

  describe "supports_temperature?/3" do
    test "returns true for unrestricted models" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.supports_temperature?(registry, "gpt-4", 0.5) == true
      assert OpenAIModelRegistry.supports_temperature?(registry, "gpt-4", 1.0) == true
      assert OpenAIModelRegistry.supports_temperature?(registry, "gpt-4", 0.0) == true
    end

    test "returns true for allowed temperature on restricted models" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.supports_temperature?(registry, "o1", 1.0) == true
    end

    test "returns false for disallowed temperature on restricted models" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.supports_temperature?(registry, "o1", 0.5) == false
    end

    test "returns true for temperature=1.0 on o3 series" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.supports_temperature?(registry, "o3", 1.0) == true
      assert OpenAIModelRegistry.supports_temperature?(registry, "o3", 0.5) == false
    end
  end

  describe "reasoning_model?/2" do
    test "returns true for o1 series" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.reasoning_model?(registry, "o1") == true
    end

    test "returns true for o3 series" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.reasoning_model?(registry, "o3") == true
      assert OpenAIModelRegistry.reasoning_model?(registry, "o3-mini") == true
    end

    test "returns true for gpt-5 series" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.reasoning_model?(registry, "gpt-5") == true
      assert OpenAIModelRegistry.reasoning_model?(registry, "gpt-5.1") == true
      assert OpenAIModelRegistry.reasoning_model?(registry, "gpt-5.2") == true
    end

    test "returns false for chat models" do
      registry = OpenAIModelRegistry.new()

      assert OpenAIModelRegistry.reasoning_model?(registry, "gpt-4") == false
      assert OpenAIModelRegistry.reasoning_model?(registry, "gpt-4o") == false
      assert OpenAIModelRegistry.reasoning_model?(registry, "gpt-5-chat-latest") == false
    end
  end

  describe "register_model/3" do
    test "adds new model to registry" do
      registry = OpenAIModelRegistry.new()

      custom_caps = %{
        model_type: :chat,
        supports_tools: false,
        supports_streaming: true,
        supports_vision: false,
        max_context_tokens: 8000,
        max_output_tokens: 4000,
        supported_temperatures: nil,
        supports_chat_api: true,
        supports_completions_api: false,
        supports_responses_api: false
      }

      new_registry = OpenAIModelRegistry.register_model(registry, "custom-model", custom_caps)
      caps = OpenAIModelRegistry.get_model_capabilities(new_registry, "custom-model")

      assert caps.supports_tools == false
      assert caps.max_context_tokens == 8000
    end
  end

  describe "register_pattern/3" do
    test "adds new pattern for model type inference" do
      registry = OpenAIModelRegistry.new()

      new_registry = OpenAIModelRegistry.register_pattern(registry, "custom-prefix", :embedding)
      caps = OpenAIModelRegistry.get_model_capabilities(new_registry, "my-custom-prefix-model")

      assert caps.model_type == :embedding
    end
  end

  describe "gpt-3.5 models" do
    test "instruct models do not support tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-3.5-turbo-instruct")

      assert caps.supports_tools == false
      assert caps.supports_streaming == false
    end

    test "turbo models support tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-3.5-turbo")

      assert caps.supports_tools == true
      assert caps.supports_streaming == true
    end
  end

  describe "special model capabilities (2026-02-04 audit)" do
    test "chatgpt-4o-latest does not support tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "chatgpt-4o-latest")

      assert caps.model_type == :chat
      assert caps.supports_tools == false
      assert caps.supports_streaming == true
    end

    test "gpt-4.1-nano does not support tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4.1-nano")

      assert caps.model_type == :chat
      assert caps.supports_tools == false
    end

    test "gpt-4.1-nano-2025-04-14 supports tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4.1-nano-2025-04-14")

      assert caps.model_type == :chat
      assert caps.supports_tools == true
    end

    test "audio preview models do not support tools or streaming" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4o-audio-preview")

      assert caps.supports_tools == false
      assert caps.supports_streaming == false
    end

    test "search preview models do not support tools or temperature" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4o-search-preview")

      assert caps.supports_tools == false
      assert caps.supports_streaming == true
      assert caps.supported_temperatures == []
    end

    test "gpt-5-chat-latest is a chat model" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-5-chat-latest")

      assert caps.model_type == :chat
      assert caps.supports_tools == true
      assert caps.supports_streaming == true
    end

    test "gpt-5-mini does not support tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-5-mini")

      assert caps.model_type == :reasoning
      assert caps.supports_tools == false
      assert caps.supports_streaming == true
    end

    test "gpt-5-search-api does not support tools or temperature" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-5-search-api")

      assert caps.model_type == :chat
      assert caps.supports_tools == false
      assert caps.supports_streaming == true
      assert caps.supported_temperatures == []
    end

    test "o4-mini supports tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "o4-mini")

      assert caps.model_type == :reasoning
      assert caps.supports_tools == true
      assert caps.supports_streaming == true
    end

    test "o4-mini-2025-04-16 supports tools" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "o4-mini-2025-04-16")

      assert caps.model_type == :reasoning
      assert caps.supports_tools == true
      assert caps.supports_streaming == true
    end
  end

  describe "API endpoint support flags" do
    test "chat-only model has correct flags" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4")

      assert caps.supports_chat_api == true
      assert caps.supports_completions_api == false
      assert caps.supports_responses_api == false
    end

    test "both-endpoint model has correct flags" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4o-mini")

      assert caps.supports_chat_api == true
      assert caps.supports_completions_api == true
      assert caps.supports_responses_api == false
    end

    test "completions-only model has correct flags" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-3.5-turbo-instruct")

      assert caps.supports_chat_api == false
      assert caps.supports_completions_api == true
      assert caps.supports_responses_api == false
    end

    test "responses-only model has correct flags" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-5-pro")

      assert caps.supports_chat_api == false
      assert caps.supports_completions_api == false
      assert caps.supports_responses_api == true
    end

    test "legacy completions model has correct flags" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "babbage-002")

      assert caps.supports_chat_api == false
      assert caps.supports_completions_api == true
      assert caps.supports_responses_api == false
    end

    test "embedding model has no endpoints" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "text-embedding-3-large")

      assert caps.supports_chat_api == false
      assert caps.supports_completions_api == false
      assert caps.supports_responses_api == false
    end

    test "codex-mini-latest is responses-only" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "codex-mini-latest")

      assert caps.supports_chat_api == false
      assert caps.supports_completions_api == false
      assert caps.supports_responses_api == true
    end

    test "gpt-5.1 supports both chat and completions" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-5.1")

      assert caps.supports_chat_api == true
      assert caps.supports_completions_api == true
      assert caps.supports_responses_api == false
    end

    test "default capabilities include endpoint flags" do
      registry = OpenAIModelRegistry.new()
      caps = OpenAIModelRegistry.get_model_capabilities(registry, "completely-unknown-model-xyz")

      assert caps.supports_chat_api == true
      assert caps.supports_completions_api == false
      assert caps.supports_responses_api == false
    end
  end
end
