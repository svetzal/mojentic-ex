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
      assert config.top_p == nil
      assert config.top_k == nil
      assert config.response_format == nil
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

    test "creates config with custom top_p" do
      config = CompletionConfig.new(top_p: 0.9)

      assert config.top_p == 0.9
      assert config.temperature == 1.0
    end

    test "creates config with custom top_k" do
      config = CompletionConfig.new(top_k: 40)

      assert config.top_k == 40
      assert config.temperature == 1.0
    end

    test "creates config with response_format as json_object" do
      format = %{type: :json_object, schema: nil}
      config = CompletionConfig.new(response_format: format)

      assert config.response_format == format
    end

    test "creates config with response_format including schema" do
      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}
      format = %{type: :json_object, schema: schema}
      config = CompletionConfig.new(response_format: format)

      assert config.response_format == format
    end

    test "creates config with response_format as text" do
      format = %{type: :text, schema: nil}
      config = CompletionConfig.new(response_format: format)

      assert config.response_format == format
    end

    test "creates config with all new fields" do
      schema = %{"type" => "object"}
      format = %{type: :json_object, schema: schema}

      config =
        CompletionConfig.new(
          temperature: 0.7,
          top_p: 0.95,
          top_k: 50,
          response_format: format
        )

      assert config.temperature == 0.7
      assert config.top_p == 0.95
      assert config.top_k == 50
      assert config.response_format == format
    end

    test "accepts zero for top_p" do
      config = CompletionConfig.new(top_p: 0.0)

      assert config.top_p == 0.0
    end

    test "accepts one for top_p" do
      config = CompletionConfig.new(top_p: 1.0)

      assert config.top_p == 1.0
    end
  end
end
