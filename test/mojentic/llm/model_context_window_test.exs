defmodule Mojentic.LLM.ModelContextWindowTest do
  use ExUnit.Case, async: true
  import Mox

  alias Mojentic.LLM.{CompletionConfig, Gateway}
  alias Mojentic.LLM.Gateways.{Ollama, OpenAIModelRegistry}
  alias Mojentic.TestSupport.ContextWindowContract

  @external_resource "test/contracts/context_window_v1.json"
  @contract ContextWindowContract.contract()
  setup :verify_on_exit!

  for row <- @contract["cases"] do
    @row row
    test "context-window-v1 consumer double #{@row["provider"]} #{@row["name"]} derives verified result" do
      result = ContextWindowContract.result(@row)

      expect(Mojentic.ContextWindowGatewayMock, :get_model_context_window, fn model ->
        assert model == @row["model"]
        result
      end)

      assert Gateway.get_model_context_window(Mojentic.ContextWindowGatewayMock, @row["model"]) ==
               result
    end
  end

  test "legacy gateway without optional callback returns not advertised without dispatch" do
    refute function_exported?(
             Mojentic.LegacyContextWindowGatewayMock,
             :get_model_context_window,
             1
           )

    assert {:ok, nil} =
             Gateway.get_model_context_window(
               Mojentic.LegacyContextWindowGatewayMock,
               "any-model"
             )

    assert {:ok, nil} = Gateway.get_model_context_window(Mojentic.UnknownGateway, "any-model")
  end

  for {row, index} <- Enum.with_index(@contract["effective_cases"]) do
    @row row
    test "context-window-v1 effective precedence and clamping #{index}" do
      window = ContextWindowContract.window(@row["window"])
      config = CompletionConfig.new(num_ctx: @row["num_ctx"])
      assert Ollama.effective_context_window(window, config) == @row["expected"]
      assert config == CompletionConfig.new(num_ctx: @row["num_ctx"])
      assert window == ContextWindowContract.window(@row["window"])
    end
  end

  test "registry metadata does not alter capability or pattern fallback" do
    registry = OpenAIModelRegistry.new()

    for model <- ["gpt-5.4-unknown", "o1-custom", "completely-unknown"] do
      capabilities = OpenAIModelRegistry.get_model_capabilities(registry, model)
      parameter = OpenAIModelRegistry.get_token_limit_param(registry, model)
      assert {:ok, nil} = OpenAIModelRegistry.get_model_context_window(registry, model)
      assert OpenAIModelRegistry.get_model_capabilities(registry, model) == capabilities
      assert OpenAIModelRegistry.get_token_limit_param(registry, model) == parameter
    end

    assert OpenAIModelRegistry.get_token_limit_param(registry, "o1-custom") ==
             "max_completion_tokens"
  end

  test "registry entries without a positive known capacity never invent a window" do
    for capacity <- [nil, 0, -1, 1.5, "8192", true] do
      registry =
        OpenAIModelRegistry.register_model(OpenAIModelRegistry.new(), "custom", %{
          max_context_tokens: capacity
        })

      expected = if is_nil(capacity), do: {:ok, nil}, else: {:error, :invalid_response}
      assert OpenAIModelRegistry.get_model_context_window(registry, "custom") == expected
    end

    registry = OpenAIModelRegistry.register_model(OpenAIModelRegistry.new(), "custom", %{})
    assert {:ok, nil} = OpenAIModelRegistry.get_model_context_window(registry, "custom")
  end
end
