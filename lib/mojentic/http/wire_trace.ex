defmodule Mojentic.HTTP.WireTrace do
  @moduledoc false

  defmodule CaptureError do
    @moduledoc false
    defexception message: "wire capture failed"
  end

  # External capture receives sensitive evidence only through the opt-in hook.
  # The recovery owner records received evidence before that hook can block.
  def notify(nil, _event), do: :ok

  def notify({callback, ids}, event) do
    case callback.(Map.put(event, :ids, ids)) do
      :ok -> :ok
      _ -> {:error, :capture_failed}
    end
  rescue
    _ -> {:error, :capture_failed}
  catch
    _, _ -> {:error, :capture_failed}
  end

  def stream(trace, request, stream, observer \\ nil, mode \\ :ordinary)

  def stream(nil, _request, stream, nil, _mode), do: stream

  def stream(trace, request, stream, observer, mode) do
    Stream.resource(
      fn ->
        continuation = &Enumerable.reduce(stream, &1, fn item, _ -> {:suspend, item} end)
        capture = notify(trace, request)

        %{
          continuation: continuation,
          capture: capture,
          observed: false,
          done: false,
          evidence: Mojentic.HTTP.ReceivedEvidence.new(mode)
        }
      end,
      &next(&1, trace, observer),
      fn state ->
        state.continuation.({:halt, nil})

        unless state.done do
          case notify(trace, %{
                 type: :response_end,
                 outcome: :consumer_halted,
                 evidence: evidence(state.observed)
               }) do
            :ok -> :ok
            _ -> raise CaptureError
          end
        end
      end
    )
  end

  defp next(%{done: true} = state, _trace, _request), do: {:halt, state}

  defp next(state, trace, observer) do
    case state.continuation.({:cont, nil}) do
      {:suspended, item, continuation} ->
        evidence = Mojentic.HTTP.ReceivedEvidence.observe(item, state.evidence)
        if observer, do: observer.(evidence)
        state = %{state | continuation: continuation, evidence: evidence}

        with :ok <- state.capture,
             :ok <- notify(trace, event(item, state.observed)) do
          {[item],
           %{
             state
             | observed: state.observed or observed?(item),
               done: match?({:error, _}, item)
           }}
        else
          _ -> {[{:error, :capture_failed}], %{state | done: true}}
        end

      {done, _} when done in [:done, :halted] ->
        evidence = Mojentic.HTTP.ReceivedEvidence.complete(state.evidence)
        if observer, do: observer.(evidence)

        case notify(trace, %{
               type: :response_end,
               outcome: :complete,
               evidence: evidence(state.observed)
             }) do
          :ok -> {[], %{state | done: true}}
          _ -> {[{:error, :capture_failed}], %{state | done: true}}
        end
    end
  end

  defp observed?({:headers, _, _}), do: true
  defp observed?({:data, _}), do: true
  defp observed?({:http_data, _}), do: true
  defp observed?(_), do: false
  defp evidence(true), do: :available
  defp evidence(false), do: :unavailable

  defp event({:headers, status, headers}, _),
    do: %{type: :response_headers, status: status, headers: headers}

  defp event({kind, body}, _) when kind in [:data, :http_data],
    do: %{type: :response_data, body: body}

  defp event({:error, _}, observed),
    do: %{type: :response_end, outcome: :failed, evidence: evidence(observed)}
end
