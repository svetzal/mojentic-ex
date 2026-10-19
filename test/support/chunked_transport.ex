defmodule Mojentic.TestSupport.ChunkedTransport do
  @moduledoc false

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  def start_link({owner, chunks, hold, status}) do
    body =
      Enum.map_join(chunks, fn chunk ->
        Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"
      end)

    response =
      "HTTP/1.1 #{status} Result\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n" <>
        body

    response =
      case hold do
        :timeout -> {:stream_error, response, :timeout}
        true -> {:stream_hold, response}
        false -> response <> "0\r\n\r\n"
      end

    {:ok, pid} = Mojentic.TestSupport.ScriptedTransport.start_link({owner, [response]})

    send(owner, {:port, GenServer.call(pid, :id)})
    {:ok, pid}
  end

  def request_body(request),
    do: request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()
end
