defmodule Mojentic.LLM.Gateways.OpenAIStream do
  @moduledoc false

  # A suspended continuation owns one HTTP request and is closed on early halt.
  def events(start) do
    Stream.resource(fn -> initialize(start) end, &next/1, &close/1)
  end

  defp initialize(start) do
    case start.() do
      {:ok, stream} ->
        continuation = &Enumerable.reduce(stream, &1, fn item, _ -> {:suspend, item} end)

        %{
          continuation: continuation,
          buffer: "",
          finish_reason: nil,
          model: nil,
          usage: nil,
          terminal: false
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next({:error, reason}), do: {[{:error, reason}], :halt}
  defp next(:halt), do: {:halt, :halt}
  defp next(%{terminal: true} = state), do: {:halt, state}

  defp next(state) do
    case state.continuation.({:cont, nil}) do
      {:suspended, {:data, chunk}, continuation} ->
        parse(%{state | continuation: continuation}, chunk)

      {:suspended, {:error, reason}, continuation} ->
        {[{:error, reason}], %{state | continuation: continuation, terminal: true}}

      {done, _} when done in [:done, :halted] ->
        {[{:error, :incomplete_stream}], %{state | terminal: true}}
    end
  end

  defp parse(state, chunk) do
    lines = String.split(state.buffer <> chunk, "\n")
    {complete, [buffer]} = Enum.split(lines, -1)

    Enum.reduce_while(complete, {[], %{state | buffer: buffer}}, fn line, {events, current} ->
      {new_events, updated} = parse_line(String.trim_trailing(line, "\r"), current)
      result = {events ++ new_events, updated}
      if updated.terminal, do: {:halt, result}, else: {:cont, result}
    end)
  end

  defp parse_line("data: [DONE]", %{finish_reason: "stop"} = state),
    do:
      {[{:completed, %{finish_reason: "stop", usage: state.usage, model: state.model}}],
       %{state | terminal: true}}

  defp parse_line("data: [DONE]", state),
    do:
      fail(
        state,
        {:incomplete_completion,
         %{finish_reason: state.finish_reason, usage: state.usage, model: state.model}}
      )

  defp parse_line("data: " <> data, state) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} ->
        fail(state, {:provider_error, error})

      {:ok, %{"choices" => [%{"delta" => delta} = choice]} = object} ->
        parse_delta(delta, choice["finish_reason"], %{
          state
          | model: object["model"] || state.model,
            usage: object["usage"] || state.usage
        })

      {:ok, %{"choices" => [], "usage" => usage}} ->
        {[], %{state | usage: usage}}

      _ ->
        fail(state, :invalid_stream_event)
    end
  end

  defp parse_line(_comment_or_blank, state), do: {[], state}

  defp parse_delta(%{"tool_calls" => calls}, _reason, state) when calls != [],
    do: fail(state, :unexpected_tool_calls)

  defp parse_delta(delta, reason, state) do
    state = if reason, do: %{state | finish_reason: reason}, else: state

    case Map.get(delta, "content") do
      nil -> {[], state}
      text when is_binary(text) -> {[{:content, text}], state}
      _ -> fail(state, :invalid_stream_content)
    end
  end

  defp fail(state, reason), do: {[{:error, reason}], %{state | terminal: true}}
  defp close(%{continuation: continuation}), do: continuation.({:halt, nil})
  defp close(_), do: :ok
end
