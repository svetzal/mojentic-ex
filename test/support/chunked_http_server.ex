defmodule Mojentic.TestSupport.ChunkedHTTPServer do
  @moduledoc false
  # A one-connection HTTP server for streaming gateway tests. It accepts one
  # request, reports it to the owner, and replies with the given chunks using
  # chunked transfer encoding. With `hold`, it keeps the response open and
  # reports what happens when the client closes the connection.
  #
  # Messages sent to the owner:
  #   {:port, port}             when the listener is ready
  #   {:request, raw_request}   when the request arrives
  #   {:cancel_result, result}  with `hold`, when the client closes or times out

  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init({owner, chunks, hold, status}) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    send(owner, {:port, port})
    {:ok, {owner, listener, chunks, hold, status}, {:continue, :serve}}
  end

  @impl true
  def handle_continue(:serve, {owner, listener, chunks, hold, status} = state) do
    {:ok, socket} = :gen_tcp.accept(listener, 2000)
    :gen_tcp.close(listener)
    {:ok, request} = :gen_tcp.recv(socket, 0, 2000)
    send(owner, {:request, request})

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} Result\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      )

    for chunk <- chunks do
      :ok =
        :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
    end

    if hold do
      send(owner, {:cancel_result, :gen_tcp.recv(socket, 0, 2000)})
    else
      :gen_tcp.send(socket, "0\r\n\r\n")
    end

    :gen_tcp.close(socket)
    {:noreply, state}
  end

  @doc "Returns the decoded JSON body of a raw HTTP request."
  def request_body(request) do
    request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()
  end
end
