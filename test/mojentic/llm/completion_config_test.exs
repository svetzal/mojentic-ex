defmodule Mojentic.LLM.CompletionConfigTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.CompletionConfig

  describe "new/0" do
    test "creates config with default values" do
      config = CompletionConfig.new()

      assert config.temperature == 1.0
      assert config.num_ctx == 32_768
      assert config.max_tokens == 16_384
      assert config.num_predict == nil
    end
  end

  describe "new/1" do
    test "creates config with custom temperature" do
      config = CompletionConfig.new(temperature: 0.7)

      assert config.temperature == 0.7
      assert config.num_ctx == 32_768
      assert config.max_tokens == 16_384
    end

    test "creates config with custom max_tokens" do
      config = CompletionConfig.new(max_tokens: 1000)

      assert config.temperature == 1.0
      assert config.num_ctx == 32_768
      assert config.max_tokens == 1000
    end

    test "creates config with custom num_ctx" do
      config = CompletionConfig.new(num_ctx: 4096)

      assert config.temperature == 1.0
      assert config.num_ctx == 4096
      assert config.max_tokens == 16_384
    end

    test "creates config with custom num_predict" do
      config = CompletionConfig.new(num_predict: 512)

      assert config.temperature == 1.0
      assert config.num_predict == 512
    end

    test "creates config with multiple overrides" do
      config =
        CompletionConfig.new(
          temperature: 0.5,
          max_tokens: 2000,
          num_ctx: 8192,
          num_predict: 1024
        )

      assert config.temperature == 0.5
      assert config.num_ctx == 8192
      assert config.max_tokens == 2000
      assert config.num_predict == 1024
    end

    test "accepts zero temperature" do
      config = CompletionConfig.new(temperature: 0.0)

      assert config.temperature == 0.0
    end

    test "accepts high temperature" do
      config = CompletionConfig.new(temperature: 2.0)

      assert config.temperature == 2.0
    end
  end
end
