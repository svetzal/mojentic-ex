defmodule Mojentic.Realtime.Schemas do
  @moduledoc """
  Boundary validation for OpenAI Realtime API server events.

  Validates that recognised event types carry their required fields;
  unknown fields are tolerated (provider drift won't crash parsing).
  Unrecognised event types pass through verbatim so callers can still
  consume them via the raw event stream.

  Schema snapshot: OpenAI Realtime API beta circa 2026-05.
  """

  @required_fields %{
    "session.created" => [["session", "id"]],
    "session.updated" => [["session"]],
    "input_audio_buffer.speech_started" => [],
    "input_audio_buffer.speech_stopped" => [],
    "conversation.item.input_audio_transcription.completed" => [["item_id"], ["transcript"]],
    "conversation.item.input_audio_transcription.delta" => [["item_id"], ["delta"]],
    "response.created" => [["response", "id"]],
    "response.done" => [["response"]],
    "response.output_item.added" => [["response_id"], ["item"]],
    "response.output_item.done" => [["response_id"], ["item"]],
    "response.audio.delta" => [["response_id"], ["delta"]],
    "response.output_audio.delta" => [["response_id"], ["delta"]],
    "response.audio_transcript.delta" => [["response_id"], ["delta"]],
    "response.output_audio_transcript.delta" => [["response_id"], ["delta"]],
    "response.audio_transcript.done" => [["response_id"], ["transcript"]],
    "response.output_audio_transcript.done" => [["response_id"], ["transcript"]],
    "response.text.delta" => [["response_id"], ["delta"]],
    "response.output_text.delta" => [["response_id"], ["delta"]],
    "response.text.done" => [["response_id"], ["text"]],
    "response.output_text.done" => [["response_id"], ["text"]],
    "response.function_call_arguments.delta" => [["response_id"], ["call_id"], ["delta"]],
    "response.function_call_arguments.done" => [
      ["response_id"],
      ["call_id"],
      ["name"],
      ["arguments"]
    ],
    "rate_limits.updated" => [["rate_limits"]],
    "error" => [["error"]]
  }

  @doc """
  Best-effort parse: returns the raw map when the event is recognised
  and all required fields are present. Falls back to the original
  payload otherwise so callers can still surface unrecognised /
  malformed events.

  A payload without a `"type"` key becomes `%{"type" => "unknown"}`.
  """
  def parse_server_event(raw) when is_map(raw) do
    type = Map.get(raw, "type")

    cond do
      type == nil ->
        %{"type" => "unknown"}

      Map.has_key?(@required_fields, type) ->
        if all_present?(raw, Map.fetch!(@required_fields, type)), do: raw, else: raw

      true ->
        raw
    end
  end

  def parse_server_event(_other), do: %{"type" => "unknown"}

  defp all_present?(_raw, []), do: true
  defp all_present?(raw, paths), do: Enum.all?(paths, &has_path?(raw, &1))

  defp has_path?(_raw, []), do: true

  defp has_path?(raw, [key | rest]) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, value} -> has_path?(value, rest)
      :error -> false
    end
  end

  defp has_path?(_raw, _path), do: false

  @doc "List the event types this module recognises."
  def known_types, do: Map.keys(@required_fields)
end
