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
  def finish(_state), do: []

  defp parse_line("data: [DONE]", %{finish_reason: "stop"} = state),
    do: {[{:completed, evidence(state)}], state}

  defp parse_line("data: [DONE]", state),
    do: {[{:error, {:incomplete_completion, evidence(state)}}], state}

  defp parse_line("data: " <> data, state) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} ->
        {[{:error, {:provider_error, error}}], state}

      {:ok, %{"choices" => [%{"delta" => delta} = choice]} = object} ->
        parse_delta(delta, choice["finish_reason"], %{
          state
          | model: object["model"] || state.model,
            usage: object["usage"] || state.usage
        })

      {:ok, %{"choices" => [], "usage" => usage}} ->
        {[], %{state | usage: usage}}

      _ ->
        {[{:error, :invalid_stream_event}], state}
    end
  end

  defp parse_line(_comment_or_blank, state), do: {[], state}

  defp parse_delta(%{"tool_calls" => calls}, _reason, state) when calls != [],
    do: {[{:error, :unexpected_tool_calls}], state}

  defp parse_delta(delta, reason, state) do
    state = if reason, do: %{state | finish_reason: reason}, else: state

    case Map.get(delta, "content") do
      nil -> {[], state}
      text when is_binary(text) -> {[{:content, text}], state}
      _ -> {[{:error, :invalid_stream_content}], state}
    end
  end

  defp evidence(state),
    do: %{finish_reason: state.finish_reason, usage: state.usage, model: state.model}
end
