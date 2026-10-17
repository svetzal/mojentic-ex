defmodule Mojentic.LLM.Reasoning do
  @moduledoc false
  alias Mojentic.LLM.ReasoningProfile

  @efforts [:disabled, :enabled, :low, :medium, :high, :xhigh]

  def validate(config, messages, provider) do
    with :ok <- validate_controls(config),
         :ok <- validate_profile(config) do
      validate_provider(config, messages, provider)
    end
  end

  def ollama_control(:disabled), do: false
  def ollama_control(:enabled), do: true
  def ollama_control(effort), do: to_string(effort)

  def omlx_controls(body, config) do
    body =
      case config.reasoning_effort do
        nil -> body
        :disabled -> Map.put(body, :enable_thinking, false)
        :enabled -> Map.put(body, :enable_thinking, true)
        effort -> Map.put(body, :reasoning_effort, to_string(effort))
      end

    if config.preserve_reasoning,
      do: Map.put(body, :chat_template_kwargs, %{preserve_thinking: true}),
      else: body
  end

  def put_history(body, %{role: :assistant, reasoning_content: text}, key)
      when is_binary(text),
      do: Map.put(body, key, text)

  def put_history(body, _message, _key), do: body

  defp validate_controls(%{reasoning_effort: effort, preserve_reasoning: preserve})
       when (effort in @efforts or is_nil(effort)) and is_boolean(preserve),
       do: :ok

  defp validate_controls(_), do: {:error, :invalid_reasoning_controls}

  defp validate_profile(%{reasoning_profile: nil}), do: :ok

  defp validate_profile(%{reasoning_profile: %ReasoningProfile{} = profile} = config),
    do: ReasoningProfile.validate(profile, config.reasoning_effort, config.preserve_reasoning)

  defp validate_profile(_), do: {:error, :invalid_reasoning_profile}

  defp validate_provider(config, messages, :openai) do
    if config.preserve_reasoning or config.reasoning_profile != nil or
         config.reasoning_effort in [:disabled, :enabled, :xhigh] or
         Enum.any?(messages, &(&1.reasoning_content != nil)) do
      {:error, :unsupported_openai_reasoning_controls}
    else
      :ok
    end
  end

  defp validate_provider(_config, _messages, _provider), do: :ok
end
