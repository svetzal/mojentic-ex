defmodule Mojentic.LLM.Gateways.OpenAIStream do
  @moduledoc false

  # OpenAI-compatible server-sent events. Completion requires a finish reason of
  # "stop" and the `data: [DONE]` marker.

  @behaviour Mojentic.LLM.Gateways.TerminalEventStream

  alias Mojentic.LLM.Gateways.TerminalEventStream

  def events(start), do: TerminalEventStream.events(start, __MODULE__)

  @impl TerminalEventStream
  def new, do: %{buffer: "", finish_reason: nil, model: nil, usage: nil}

  @impl TerminalEventStream
  def parse(state, chunk) do
    lines = String.split(state.buffer <> chunk, "\n")
    {complete, [buffer]} = Enum.split(lines, -1)

    Enum.reduce(complete, {[], %{state | buffer: buffer}}, fn line, {events, current} ->
      {new_events, updated} = parse_line(String.trim_trailing(line, "\r"), current)
      {events ++ new_events, updated}
    end)
  end

  # An SSE event is complete only when its line ends; a partial line is dropped.
  @impl TerminalEventStream
  def finish(state), do: {[], evidence(state)}

  defp parse_line("data: [DONE]", %{finish_reason: "stop"} = state),
    do: {[{:completed, evidence(state)}], state}

  defp parse_line("data: [DONE]", state),
    do: {[{:error, {:incomplete_completion, evidence(state)}}], state}

  defp parse_line("data: " <> data, state) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} ->
        {[{:error, {:provider_error, error}}], state}

      {:ok, %{"choices" => [%{"delta" => delta} = choice]} = object} ->
        if valid_evidence?(object) and is_map(delta) and
             (is_nil(choice["finish_reason"]) or is_binary(choice["finish_reason"])) do
          parse_delta(delta, choice["finish_reason"], update_evidence(state, object))
        else
          {[{:error, :invalid_stream_event}], state}
        end

      {:ok, %{"choices" => [], "usage" => _usage} = object} ->
        if valid_evidence?(object) do
          {[], update_evidence(state, object)}
        else
          {[{:error, :invalid_stream_event}], state}
        end

      _ ->
        {[{:error, :invalid_stream_event}], state}
    end
  end

  defp parse_line(_comment_or_blank, state), do: {[], state}

  defp parse_delta(%{"tool_calls" => calls}, _reason, state)
       when is_list(calls) and calls != [] do
    reason =
      if Enum.all?(calls, &is_map/1), do: :unexpected_tool_calls, else: :invalid_stream_event

    {[{:error, reason}], state}
  end

  defp parse_delta(%{"tool_calls" => calls}, _reason, state)
       when not is_nil(calls) and calls != [],
       do: {[{:error, :invalid_stream_event}], state}

  defp parse_delta(delta, reason, state) do
    state = if reason, do: %{state | finish_reason: reason}, else: state

    case Map.get(delta, "content") do
      nil -> {[], state}
      text when is_binary(text) -> {[{:content, text}], state}
      _ -> {[{:error, :invalid_stream_content}], state}
    end
  end

  defp valid_evidence?(object),
    do:
      (is_nil(object["model"]) or is_binary(object["model"])) and
        (is_nil(object["usage"]) or is_map(object["usage"]))

  defp update_evidence(state, object),
    do: %{state | model: object["model"] || state.model, usage: object["usage"] || state.usage}

  defp evidence(state),
    do: %{
      finish_reason: state.finish_reason,
      usage: state.usage,
      provider_model: state.model,
      metadata: nil
    }
end
