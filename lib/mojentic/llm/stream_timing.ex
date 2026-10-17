defmodule Mojentic.LLM.StreamTiming do
  @moduledoc false

  alias Mojentic.LLM.{CompletionError, MonotonicClock}

  # The HTTP worker and recovery owner share only numeric measurements. Each
  # enumeration creates a new clock, shared by its sequential admitted attempts.
  # Slots hold the dispatch flag, dispatch time and packed first observation.
  def new(provider) do
    %{
      values: :atomics.new(3, signed: true),
      clock: Application.get_env(:mojentic, :monotonic_clock, MonotonicClock),
      provider: provider
    }
  end

  def dispatch(nil), do: :ok

  def dispatch(timing) do
    if :atomics.get(timing.values, 1) == 0 do
      :atomics.put(timing.values, 2, timing.clock.now())
      :atomics.put(timing.values, 1, 1)
    end

    :ok
  end

  def observe(_item, nil, buffer), do: buffer
  def observe(_item, _timing, :terminal), do: :terminal

  def observe({:data, chunk}, timing, buffer) do
    {lines, [buffer]} = String.split(buffer <> chunk, "\n") |> Enum.split(-1)

    Enum.reduce_while(lines, buffer, fn line, _buffer ->
      case frame(String.trim(line), timing) do
        :terminal -> {:halt, :terminal}
        _ -> {:cont, buffer}
      end
    end)
  end

  def observe(_item, _timing, buffer), do: buffer

  def legacy_argument_fragment?(%{"function_call" => %{"arguments" => arguments}}),
    do: present?(arguments)

  def legacy_argument_fragment?(_delta), do: false

  # EOF also delimits Ollama's supported final JSON frame without a newline.
  # Observe it before response-end capture can delay, reject or cancel acceptance.
  def finish(%{provider: :ollama} = timing, buffer) when is_binary(buffer) do
    frame(String.trim(buffer), timing)
    :ok
  end

  def finish(_timing, _buffer), do: :ok

  def metadata(timing) do
    if :atomics.get(timing.values, 1) == 0 do
      %{}
    else
      start = :atomics.get(timing.values, 2)
      metadata = %{request_duration_ms: max(timing.clock.now() - start, 0)}

      case :atomics.get(timing.values, 3) do
        0 ->
          metadata

        observation ->
          Map.merge(metadata, %{
            time_to_first_token_ms: div(observation, 4),
            first_token_kind: Enum.at([:thinking, :content, :tool_call], rem(observation, 4) - 1)
          })
      end
    end
  end

  def evidence(evidence, timing) do
    case metadata(timing) do
      metadata when map_size(metadata) == 0 -> evidence
      metadata -> Map.update(evidence, :metadata, metadata, &Map.merge(&1 || %{}, metadata))
    end
  end

  def error(%CompletionError{} = error, timing),
    do: %{error | metadata: Map.merge(error.metadata, metadata(timing))}

  def error({kind, evidence}, timing)
      when is_map(evidence) and kind in [:incomplete_stream, :incomplete_completion],
      do: {kind, evidence(evidence, timing)}

  def error(reason, timing) do
    case metadata(timing) do
      metadata when map_size(metadata) == 0 -> reason
      metadata -> {:stream_error, reason, %{metadata: metadata}}
    end
  end

  # Recovery-disabled adapters retain their parsers and request bodies. This
  # wrapper adds terminal evidence while owning the same HTTP continuation.
  def wrap(provider, start) do
    Stream.resource(
      fn ->
        timing = new(provider)
        stream = start.(timing)

        %{
          timing: timing,
          continuation: &Enumerable.reduce(stream, &1, fn item, _ -> {:suspend, item} end),
          done: false
        }
      end,
      &next/1,
      fn
        %{continuation: continuation} when is_function(continuation) ->
          continuation.({:halt, nil})

        _ ->
          :ok
      end
    )
  end

  defp frame("data: " <> data, timing), do: frame(data, timing)
  defp frame("[DONE]", _timing), do: :terminal

  defp frame(data, timing) do
    case Jason.decode(data) do
      {:ok, %{"model" => "keepalive"}} when timing.provider == :omlx ->
        :ok

      {:ok, object} when is_map(object) ->
        record(kind(message(object)), timing)
        if object["done"] == true, do: :terminal, else: :ok

      _ ->
        :ok
    end
  end

  defp message(%{"message" => message}) when is_map(message), do: message
  defp message(%{"choices" => [%{"delta" => delta} | _]}) when is_map(delta), do: delta
  defp message(_), do: %{}

  defp kind(delta) do
    cond do
      present?(delta["thinking"]) or present?(delta["reasoning_content"]) -> 1
      present?(delta["content"]) -> 2
      arguments?(delta) -> 3
      true -> 0
    end
  end

  defp arguments?(delta) do
    calls = delta["tool_calls"]

    (is_list(calls) and Enum.any?(calls, &call_arguments?/1)) or
      legacy_argument_fragment?(delta)
  end

  defp call_arguments?(%{"function" => %{"arguments" => arguments}}),
    do: present?(arguments) or is_map(arguments)

  defp call_arguments?(_), do: false
  defp present?(text), do: is_binary(text) and byte_size(text) > 0

  defp record(0, _timing), do: :ok

  defp record(kind, timing) do
    if :atomics.get(timing.values, 3) == 0 do
      elapsed = max(timing.clock.now() - :atomics.get(timing.values, 2), 0)
      # Publish kind and latency atomically: cancellation can kill the observer.
      :atomics.put(timing.values, 3, elapsed * 4 + kind)
    end
  end

  defp next(%{done: true} = state), do: {:halt, state}

  defp next(state) do
    case state.continuation.({:cont, nil}) do
      {:suspended, {:completed, evidence}, rest} ->
        rest.({:halt, nil})

        {[{:completed, evidence(evidence, state.timing)}],
         %{state | continuation: nil, done: true}}

      {:suspended, {:error, reason}, rest} ->
        rest.({:halt, nil})
        {[{:error, error(reason, state.timing)}], %{state | continuation: nil, done: true}}

      {:suspended, item, rest} ->
        {[item], %{state | continuation: rest}}

      {done, _} when done in [:done, :halted] ->
        {[{:completed, evidence(%{}, state.timing)}], %{state | continuation: nil, done: true}}
    end
  end
end
