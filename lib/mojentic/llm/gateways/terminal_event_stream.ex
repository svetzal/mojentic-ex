defmodule Mojentic.LLM.Gateways.TerminalEventStream do
  @moduledoc false

  # Drives one streaming HTTP response through a provider frame parser and
  # yields `{:content, text}` events followed by exactly one terminal event:
  # `{:completed, evidence}` or `{:error, reason}`. Nothing follows the terminal
  # event. A suspended continuation owns the single HTTP request; reaching the
  # terminal event or halting enumeration closes it. Transport errors are
  # terminal, and a body that ends before the parser proves completion is
  # `{:error, :incomplete_stream}`.

  @type event :: {:content, String.t()} | {:completed, map()} | {:error, term()}

  @doc "Returns a fresh parser state."
  @callback new() :: term()

  @doc "Parses one body chunk. Events after a terminal event are discarded."
  @callback parse(state :: term(), chunk :: binary()) :: {[event()], term()}

  @doc "Parses whatever the parser still holds when the body ends."
  @callback finish(state :: term()) :: [event()]

  @spec events((-> {:ok, Enumerable.t()} | {:error, term()}), module()) :: Enumerable.t()
  def events(start, parser) do
    Stream.resource(fn -> open(start, parser) end, &next/1, &close/1)
  end

  defp open(start, parser) do
    case start.() do
      {:ok, body} ->
        %{
          continuation: &Enumerable.reduce(body, &1, fn item, _ -> {:suspend, item} end),
          parser: parser,
          parser_state: parser.new(),
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
        {events, parser_state} = state.parser.parse(state.parser_state, chunk)
        emit(events, %{state | continuation: continuation, parser_state: parser_state})

      {:suspended, {:error, reason}, continuation} ->
        emit([{:error, reason}], %{state | continuation: continuation})

      {done, _} when done in [:done, :halted] ->
        events = state.parser.finish(state.parser_state) ++ [{:error, :incomplete_stream}]
        emit(events, %{state | continuation: nil})
    end
  end

  defp emit(events, state) do
    case Enum.split_while(events, &(not terminal?(&1))) do
      {content, []} -> {content, state}
      {content, [terminal | _]} -> {content ++ [terminal], %{state | terminal: true}}
    end
  end

  defp terminal?({kind, _}), do: kind in [:completed, :error]

  defp close(%{continuation: continuation}) when is_function(continuation),
    do: continuation.({:halt, nil})

  defp close(_), do: :ok
end
