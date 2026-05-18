defmodule Mojentic.Realtime.Schemas do
  @moduledoc """
  Schema catalogue for OpenAI Realtime API server events.

  Documents the required fields for each known event type. The
  `parse_server_event/1` function normalises missing-type payloads and
  passes all recognised and unknown events through verbatim — the live
  path in `Session` pattern-matches event types directly, so no hard
  validation is needed here.

  Callers that need to validate a payload in tests can use
  `valid?/1` to check that required fields are present.

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
  Normalise a raw server-event map: ensures a `"type"` key is present.

  - Maps without a `"type"` key are tagged `%{"type" => "unknown"}`.
  - All other maps are returned verbatim — unknown event types from
    provider drift pass through so callers can still consume them.
  """
  def parse_server_event(raw) when is_map(raw) do
    if Map.has_key?(raw, "type"), do: raw, else: %{"type" => "unknown"}
  end

  def parse_server_event(_other), do: %{"type" => "unknown"}

  @doc """
  Returns `true` when a recognised event's required fields are all present.

  Unknown event types (not in the schema catalogue) always return `true`
  so callers don't need to guard against future provider additions.
  """
  def valid?(raw) when is_map(raw) do
    type = Map.get(raw, "type")

    case Map.fetch(@required_fields, type) do
      {:ok, paths} -> all_present?(raw, paths)
      :error -> true
    end
  end

  def valid?(_), do: false

  @doc "List the event types this module recognises."
  def known_types, do: Map.keys(@required_fields)

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
end
