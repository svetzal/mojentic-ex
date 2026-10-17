defmodule Mojentic.LLM.ReasoningProfile do
  @moduledoc """
  Caller-selected native reasoning capabilities. Profiles are never inferred from
  model names. Omitted effort is unknown, even with a profile selected.
  """
  @enforce_keys [:name, :supported_efforts, :supports_reasoning_history]
  defstruct [:name, :supported_efforts, :supports_reasoning_history]

  @type t :: %__MODULE__{
          name: String.t(),
          supported_efforts: [Mojentic.LLM.CompletionConfig.reasoning_effort()],
          supports_reasoning_history: boolean()
        }

  @doc "Qwen3.8's exact controls and native history capability; imposes no default."
  @spec qwen3_8() :: t()
  def qwen3_8 do
    %__MODULE__{
      name: "qwen3.8",
      supported_efforts: [:disabled, :low, :medium, :xhigh],
      supports_reasoning_history: true
    }
  end

  @doc false
  def validate(
        %__MODULE__{name: name, supported_efforts: efforts, supports_reasoning_history: history} =
          profile,
        effort,
        preserve
      )
      when is_binary(name) and is_list(efforts) and is_boolean(history) do
    cond do
      effort != nil and effort not in profile.supported_efforts ->
        {:error, {:unsupported_reasoning_effort, profile.name, effort}}

      preserve and not profile.supports_reasoning_history ->
        {:error, {:unsupported_reasoning_history, profile.name}}

      true ->
        :ok
    end
  end

  def validate(_profile, _effort, _preserve), do: {:error, :invalid_reasoning_profile}
end
