defmodule Mojentic.LLM.Gateways.OllamaStream do
  @moduledoc false

  # Ollama newline-delimited JSON chat frames. Completion requires a final frame
  # with `done: true` and a `done_reason` of "stop". A final frame without
  # `done_reason` (servers too old to send it) is an incomplete completion.
  # Thinking text is not visible assistant content and is not yielded.

  @behaviour Mojentic.LLM.Gateways.TerminalEventStream

  alias Mojentic.LLM.Gateways.Ollama
  alias Mojentic.LLM.Gateways.TerminalEventStream

  def events(start), do: TerminalEventStream.events(start, __MODULE__)

  @impl TerminalEventStream
  def new, do: %{buffer: "", model: nil}

  @impl TerminalEventStream
  def parse(state, chunk) do
    lines = String.split(state.buffer <> chunk, "\n")
    {complete, [buffer]} = Enum.split(lines, -1)
    parse_lines(complete, %{state | buffer: buffer})
  end

  # Ollama may end the body without a newline after the final frame. Usage,
  # done_reason and durations arrive only in the final frame, so a body that
  # ends early can only have reported the model.
  @impl TerminalEventStream
  def finish(state) do
    {events, state} = parse_lines([state.buffer], %{state | buffer: ""})
    {events, evidence(%{}, state)}
  end

  defp parse_lines(lines, state) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({[], state}, fn line, {events, current} ->
      {new_events, updated} = parse_line(line, current)
      {events ++ new_events, updated}
    end)
  end

  defp parse_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"error" => error}} ->
        {[{:error, {:provider_error, error}}], state}

      {:ok, %{"done" => done} = frame} when is_boolean(done) ->
        state = %{state | model: frame["model"] || state.model}
        {content_events(Map.get(frame, "message", %{})) ++ done_events(frame, state), state}

      _ ->
        {[{:error, :invalid_stream_event}], state}
    end
  end

  defp content_events(%{"tool_calls" => calls}) when is_list(calls) and calls != [],
    do: [{:error, :unexpected_tool_calls}]

  defp content_events(%{"content" => text}) when is_binary(text) and text != "",
    do: [{:content, text}]

  defp content_events(%{"content" => text}) when not is_nil(text) and not is_binary(text),
    do: [{:error, :invalid_stream_content}]

  defp content_events(message) when is_map(message), do: []
  defp content_events(_message), do: [{:error, :invalid_stream_event}]

  defp done_events(%{"done" => false}, _state), do: []

  defp done_events(%{"done_reason" => "stop"} = frame, state),
    do: [{:completed, evidence(frame, state)}]

  defp done_events(frame, state),
    do: [{:error, {:incomplete_completion, evidence(frame, state)}}]

  defp evidence(frame, state),
    do: %{
      finish_reason: frame["done_reason"],
      usage: Ollama.reported_usage(frame),
      provider_model: state.model,
      metadata: Ollama.reported_timings(frame)
    }
end
