defmodule Mojentic.Realtime.ServerVadConfig do
  @moduledoc """
  Tunable parameters for server-side voice-activity detection.
  """
  defstruct type: :server_vad,
            threshold: nil,
            prefix_padding_ms: nil,
            silence_duration_ms: nil,
            create_response: nil,
            interrupt_response: nil,
            idle_timeout_ms: nil

  @type t :: %__MODULE__{}
end

defmodule Mojentic.Realtime.SemanticVadConfig do
  @moduledoc "LLM-classifier-driven VAD."
  defstruct type: :semantic_vad,
            eagerness: nil,
            create_response: nil,
            interrupt_response: nil

  @type t :: %__MODULE__{}
end

defmodule Mojentic.Realtime.Config do
  @moduledoc """
  Vendor-neutral configuration for a realtime voice session.

  The library forwards a curated subset to the active gateway and
  translates vendor-specific shapes at the boundary. Mirrors
  RealtimeVoiceConfig in mojentic-py / mojentic-ts.
  """

  alias Mojentic.Realtime.SemanticVadConfig
  alias Mojentic.Realtime.ServerVadConfig

  defstruct instructions: nil,
            voice: nil,
            modalities: nil,
            input_audio_format: nil,
            output_audio_format: nil,
            turn_detection: nil,
            input_audio_transcription: nil,
            tools: nil,
            tool_choice: nil,
            temperature: nil,
            max_response_output_tokens: nil,
            on_interrupt: nil,
            provider_extras: nil

  @type modality :: :audio | :text
  @type audio_format :: :pcm16 | :g711_ulaw | :g711_alaw
  @type interrupt_policy :: :drop | :submit | :submit_completed_only
  @type tool_choice ::
          :auto
          | :none
          | :required
          | %{name: String.t()}
  @type turn_detection_mode ::
          :server_vad
          | :semantic_vad
          | :none
          | ServerVadConfig.t()
          | SemanticVadConfig.t()

  @type t :: %__MODULE__{
          instructions: String.t() | nil,
          voice: String.t() | nil,
          modalities: [modality()] | nil,
          input_audio_format: audio_format() | nil,
          output_audio_format: audio_format() | nil,
          turn_detection: turn_detection_mode() | nil,
          input_audio_transcription: map() | false | nil,
          tools: [module() | struct()] | nil,
          tool_choice: tool_choice() | nil,
          temperature: float() | nil,
          max_response_output_tokens: pos_integer() | nil,
          on_interrupt: interrupt_policy() | nil,
          provider_extras: map() | nil
        }

  @doc "Defaults applied when a field is omitted."
  def defaults do
    %{
      modalities: [:audio, :text],
      input_audio_format: :pcm16,
      output_audio_format: :pcm16,
      turn_detection: :server_vad,
      tool_choice: :auto,
      on_interrupt: :drop
    }
  end

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
