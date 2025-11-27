defmodule Mojentic.LLM.Gateways.OpenAIModelRegistry do
  @moduledoc """
  OpenAI Model Registry for managing model-specific configurations and capabilities.

  This module provides infrastructure for categorizing OpenAI models and managing
  their specific parameter requirements and capabilities.

  ## Model Types

  - `:reasoning` - Models like o1, o3 that use max_completion_tokens
  - `:chat` - Standard chat models that use max_tokens
  - `:embedding` - Text embedding models
  - `:moderation` - Content moderation models

  ## Examples

      iex> registry = OpenAIModelRegistry.new()
      iex> OpenAIModelRegistry.is_reasoning_model?(registry, "o1")
      true
      iex> OpenAIModelRegistry.is_reasoning_model?(registry, "gpt-4")
      false

  """

  @type model_type :: :reasoning | :chat | :embedding | :moderation

  @type model_capabilities :: %{
          model_type: model_type(),
          supports_tools: boolean(),
          supports_streaming: boolean(),
          supports_vision: boolean(),
          max_context_tokens: non_neg_integer() | nil,
          max_output_tokens: non_neg_integer() | nil,
          supported_temperatures: [float()] | nil
        }

  @type t :: %__MODULE__{
          models: %{String.t() => model_capabilities()},
          pattern_mappings: %{String.t() => model_type()}
        }

  defstruct models: %{}, pattern_mappings: %{}

  @doc """
  Creates a new model registry with default models.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
    |> initialize_reasoning_models()
    |> initialize_chat_models()
    |> initialize_embedding_models()
    |> initialize_pattern_mappings()
  end

  @doc """
  Gets the capabilities for a specific model.

  Falls back to pattern matching for unknown models, and defaults
  to chat model capabilities if no match is found.
  """
  @spec get_model_capabilities(t(), String.t()) :: model_capabilities()
  def get_model_capabilities(%__MODULE__{models: models, pattern_mappings: patterns}, model_name) do
    # Direct lookup first
    case Map.get(models, model_name) do
      nil ->
        # Pattern matching for unknown models
        model_lower = String.downcase(model_name)

        case find_matching_pattern(model_lower, patterns) do
          nil ->
            # Default to chat model
            default_capabilities_for_type(:chat)

          model_type ->
            default_capabilities_for_type(model_type)
        end

      capabilities ->
        capabilities
    end
  end

  @doc """
  Gets the correct parameter name for token limits based on model type.
  """
  @spec get_token_limit_param(t(), String.t()) :: String.t()
  def get_token_limit_param(registry, model_name) do
    capabilities = get_model_capabilities(registry, model_name)

    case capabilities.model_type do
      :reasoning -> "max_completion_tokens"
      _ -> "max_tokens"
    end
  end

  @doc """
  Checks if a model supports a specific temperature value.
  """
  @spec supports_temperature?(t(), String.t(), float()) :: boolean()
  def supports_temperature?(registry, model_name, temperature) do
    capabilities = get_model_capabilities(registry, model_name)

    case capabilities.supported_temperatures do
      nil -> true
      [] -> false
      temps -> Enum.any?(temps, fn t -> abs(t - temperature) < 0.01 end)
    end
  end

  @doc """
  Checks if a model is a reasoning model.
  """
  @spec reasoning_model?(t(), String.t()) :: boolean()
  def reasoning_model?(registry, model_name) do
    capabilities = get_model_capabilities(registry, model_name)
    capabilities.model_type == :reasoning
  end

  @doc """
  Gets a list of all explicitly registered models.
  """
  @spec get_registered_models(t()) :: [String.t()]
  def get_registered_models(%__MODULE__{models: models}) do
    Map.keys(models)
  end

  @doc """
  Registers a new model with its capabilities.
  """
  @spec register_model(t(), String.t(), model_capabilities()) :: t()
  def register_model(%__MODULE__{models: models} = registry, model_name, capabilities) do
    %{registry | models: Map.put(models, model_name, capabilities)}
  end

  @doc """
  Registers a pattern for inferring model types.
  """
  @spec register_pattern(t(), String.t(), model_type()) :: t()
  def register_pattern(%__MODULE__{pattern_mappings: patterns} = registry, pattern, model_type) do
    %{registry | pattern_mappings: Map.put(patterns, pattern, model_type)}
  end

  # Private functions

  defp initialize_reasoning_models(registry) do
    reasoning_models = [
      "o1",
      "o1-2024-12-17",
      "o1-mini",
      "o1-mini-2024-09-12",
      "o1-pro",
      "o1-pro-2025-03-19",
      "o3",
      "o3-2025-04-16",
      "o3-deep-research",
      "o3-deep-research-2025-06-26",
      "o3-mini",
      "o3-mini-2025-01-31",
      "o3-pro",
      "o3-pro-2025-06-10",
      "o4-mini",
      "o4-mini-2025-04-16",
      "o4-mini-deep-research",
      "o4-mini-deep-research-2025-06-26",
      "gpt-5",
      "gpt-5-2025-08-07",
      "gpt-5-chat-latest",
      "gpt-5-codex",
      "gpt-5-mini",
      "gpt-5-mini-2025-08-07",
      "gpt-5-nano",
      "gpt-5-nano-2025-08-07"
    ]

    Enum.reduce(reasoning_models, registry, fn model, acc ->
      is_deep_research = String.contains?(model, "deep-research")
      is_gpt5 = String.contains?(model, "gpt-5")
      is_o1_series = String.starts_with?(model, "o1")
      is_o3_series = String.starts_with?(model, "o3")
      is_o4_series = String.starts_with?(model, "o4")
      is_mini_or_nano = String.contains?(model, "mini") or String.contains?(model, "nano")

      # GPT-5 models may support more features than o1/o3/o4
      supports_tools = is_gpt5
      supports_streaming = is_gpt5

      # Set context and output tokens based on model tier
      {context_tokens, output_tokens} =
        cond do
          is_gpt5 ->
            if is_mini_or_nano, do: {200_000, 32_768}, else: {300_000, 50_000}

          is_deep_research ->
            {200_000, 100_000}

          true ->
            {128_000, 32_768}
        end

      # Temperature restrictions based on model series
      supported_temps =
        cond do
          is_gpt5 or is_o1_series or is_o4_series -> [1.0]
          is_o3_series -> []
          true -> nil
        end

      capabilities = %{
        model_type: :reasoning,
        supports_tools: supports_tools,
        supports_streaming: supports_streaming,
        supports_vision: false,
        max_context_tokens: context_tokens,
        max_output_tokens: output_tokens,
        supported_temperatures: supported_temps
      }

      register_model(acc, model, capabilities)
    end)
  end

  defp initialize_chat_models(registry) do
    gpt4_models = [
      "chatgpt-4o-latest",
      "gpt-4",
      "gpt-4-0125-preview",
      "gpt-4-0613",
      "gpt-4-1106-preview",
      "gpt-4-turbo",
      "gpt-4-turbo-2024-04-09",
      "gpt-4-turbo-preview",
      "gpt-4.1",
      "gpt-4.1-2025-04-14",
      "gpt-4.1-mini",
      "gpt-4.1-mini-2025-04-14",
      "gpt-4.1-nano",
      "gpt-4.1-nano-2025-04-14",
      "gpt-4o",
      "gpt-4o-2024-05-13",
      "gpt-4o-2024-08-06",
      "gpt-4o-2024-11-20",
      "gpt-4o-audio-preview",
      "gpt-4o-audio-preview-2024-10-01",
      "gpt-4o-audio-preview-2024-12-17",
      "gpt-4o-audio-preview-2025-06-03",
      "gpt-4o-mini",
      "gpt-4o-mini-2024-07-18",
      "gpt-4o-mini-audio-preview",
      "gpt-4o-mini-audio-preview-2024-12-17",
      "gpt-4o-mini-realtime-preview",
      "gpt-4o-mini-realtime-preview-2024-12-17",
      "gpt-4o-mini-search-preview",
      "gpt-4o-mini-search-preview-2025-03-11",
      "gpt-4o-mini-transcribe",
      "gpt-4o-mini-tts",
      "gpt-4o-realtime-preview",
      "gpt-4o-realtime-preview-2024-10-01",
      "gpt-4o-realtime-preview-2024-12-17",
      "gpt-4o-realtime-preview-2025-06-03",
      "gpt-4o-search-preview",
      "gpt-4o-search-preview-2025-03-11",
      "gpt-4o-transcribe"
    ]

    gpt35_models = [
      "gpt-3.5-turbo",
      "gpt-3.5-turbo-0125",
      "gpt-3.5-turbo-1106",
      "gpt-3.5-turbo-16k",
      "gpt-3.5-turbo-instruct",
      "gpt-3.5-turbo-instruct-0914"
    ]

    registry =
      Enum.reduce(gpt4_models, registry, fn model, acc ->
        vision_support =
          String.contains?(model, "gpt-4o") or
            String.contains?(model, "audio-preview") or
            String.contains?(model, "realtime")

        is_mini_or_nano = String.contains?(model, "mini") or String.contains?(model, "nano")

        is_audio =
          String.contains?(model, "audio") or
            String.contains?(model, "realtime") or
            String.contains?(model, "transcribe")

        is_gpt41 = String.contains?(model, "gpt-4.1")

        {context_tokens, output_tokens} =
          cond do
            is_gpt41 ->
              if is_mini_or_nano, do: {128_000, 16_384}, else: {200_000, 32_768}

            String.contains?(model, "gpt-4o") ->
              {128_000, 16_384}

            true ->
              {32_000, 8_192}
          end

        capabilities = %{
          model_type: :chat,
          supports_tools: true,
          supports_streaming: not is_audio,
          supports_vision: vision_support,
          max_context_tokens: context_tokens,
          max_output_tokens: output_tokens,
          supported_temperatures: nil
        }

        register_model(acc, model, capabilities)
      end)

    Enum.reduce(gpt35_models, registry, fn model, acc ->
      is_instruct = String.contains?(model, "instruct")

      capabilities = %{
        model_type: :chat,
        supports_tools: not is_instruct,
        supports_streaming: not is_instruct,
        supports_vision: false,
        max_context_tokens: 16_385,
        max_output_tokens: 4_096,
        supported_temperatures: nil
      }

      register_model(acc, model, capabilities)
    end)
  end

  defp initialize_embedding_models(registry) do
    embedding_models = [
      "text-embedding-3-large",
      "text-embedding-3-small",
      "text-embedding-ada-002"
    ]

    Enum.reduce(embedding_models, registry, fn model, acc ->
      capabilities = %{
        model_type: :embedding,
        supports_tools: false,
        supports_streaming: false,
        supports_vision: false,
        max_context_tokens: nil,
        max_output_tokens: nil,
        supported_temperatures: nil
      }

      register_model(acc, model, capabilities)
    end)
  end

  defp initialize_pattern_mappings(registry) do
    patterns = %{
      "o1" => :reasoning,
      "o3" => :reasoning,
      "o4" => :reasoning,
      "gpt-5" => :reasoning,
      "gpt-4" => :chat,
      "gpt-4.1" => :chat,
      "gpt-3.5" => :chat,
      "chatgpt" => :chat,
      "text-embedding" => :embedding,
      "text-moderation" => :moderation
    }

    %{registry | pattern_mappings: patterns}
  end

  defp find_matching_pattern(model_lower, patterns) do
    Enum.find_value(patterns, fn {pattern, model_type} ->
      if String.contains?(model_lower, pattern), do: model_type
    end)
  end

  defp default_capabilities_for_type(model_type) do
    case model_type do
      :reasoning ->
        %{
          model_type: :reasoning,
          supports_tools: false,
          supports_streaming: false,
          supports_vision: false,
          max_context_tokens: nil,
          max_output_tokens: nil,
          supported_temperatures: nil
        }

      :chat ->
        %{
          model_type: :chat,
          supports_tools: true,
          supports_streaming: true,
          supports_vision: false,
          max_context_tokens: nil,
          max_output_tokens: nil,
          supported_temperatures: nil
        }

      :embedding ->
        %{
          model_type: :embedding,
          supports_tools: false,
          supports_streaming: false,
          supports_vision: false,
          max_context_tokens: nil,
          max_output_tokens: nil,
          supported_temperatures: nil
        }

      :moderation ->
        %{
          model_type: :moderation,
          supports_tools: false,
          supports_streaming: false,
          supports_vision: false,
          max_context_tokens: nil,
          max_output_tokens: nil,
          supported_temperatures: nil
        }
    end
  end
end
