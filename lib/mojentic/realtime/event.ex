defmodule Mojentic.Realtime.Event do
  @moduledoc """
  Vendor-neutral event union for the realtime subsystem.

  All events share a `:kind` discriminator and a payload map. Pattern
  match on `kind` in `case`/`with`:

      case event.kind do
        :assistant_text_delta -> IO.write(event.payload.delta)
        :tool_call_completed -> handle_result(event.payload.result)
        :session_closed -> :ok
      end

  Use the helper constructors below for typed event construction.
  Mirrors RealtimeEvent in mojentic-py / mojentic-ts.
  """

  defstruct [:kind, :payload]

  @type kind ::
          :session_opened
          | :session_updated
          | :session_closed
          | :user_speech_started
          | :user_speech_stopped
          | :user_transcript_delta
          | :user_transcript
          | :assistant_turn_started
          | :assistant_text_delta
          | :assistant_text
          | :assistant_transcript_delta
          | :assistant_transcript
          | :assistant_audio_delta
          | :assistant_turn_completed
          | :tool_call_started
          | :tool_call_args_delta
          | :tool_call_dispatched
          | :tool_call_completed
          | :tool_call_failed
          | :tool_batch_submitted
          | :interrupted
          | :rate_limited
          | :error

  @type t :: %__MODULE__{kind: kind(), payload: map()}

  @doc "Construct an event of the given kind with payload fields."
  def new(kind, payload \\ %{}) when is_atom(kind) and is_map(payload) do
    %__MODULE__{kind: kind, payload: payload}
  end
end
