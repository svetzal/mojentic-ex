defmodule Mojentic.TestSupport.ScriptedCompletionServer do
  @moduledoc false
  use GenServer

  def start_link({owner, responses}), do: GenServer.start_link(__MODULE__, {owner, responses})

  @impl true
  def init({owner, responses}) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    send(owner, {:server_port, port})

    {:ok,
     %{
       owner: owner,
       listener: listener,
       responses: responses,
       requests: [],
       sockets: [],
       held_requests: []
     }, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    case :gen_tcp.accept(state.listener, 50) do
      {:ok, socket} ->
        request = read_request(socket, "")
        send(state.owner, {:wire_request, request})

        {response, rest} =
          case state.responses do
            [response | rest] -> {response, rest}
            [] -> {"", []}
          end

        sockets =
          case response do
            {:stream_half_close, response} ->
              :ok = :gen_tcp.send(socket, response)
              :ok = :gen_tcp.shutdown(socket, :write)
              send(state.owner, {:held_response_sent, request, response})
              [socket | state.sockets]

            {:stream_hold, response} ->
              :ok = :gen_tcp.send(socket, response)
              send(state.owner, {:held_response_sent, request, response})
              [socket | state.sockets]

            :hold ->
              [socket | state.sockets]

            response ->
              :ok = :gen_tcp.send(socket, response)
              :gen_tcp.close(socket)
              state.sockets
          end

        {:noreply,
         %{
           state
           | requests: state.requests ++ [request],
             responses: rest,
             sockets: sockets,
             held_requests:
               if(socket in sockets,
                 do: [{request, socket} | state.held_requests],
                 else: state.held_requests
               )
         }, 0}

      {:error, :timeout} ->
        {:noreply, state, 0}
    end
  end

  @impl true
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state, 0}

  # Read the client FIN on the socket that received these exact request bytes.
  # This call neither releases the response nor closes the server's socket.
  def handle_call({:peer_state, request}, _from, state) do
    {^request, socket} = List.keyfind(state.held_requests, request, 0)
    {:reply, :gen_tcp.recv(socket, 0, 500), state, 0}
  end

  def handle_call(:closed_sockets, _from, state) do
    results =
      Enum.map(state.sockets, fn socket ->
        case :gen_tcp.recv(socket, 0, 2000) do
          {:error, :closed} -> :closed
          other -> other
        end
      end)

    {:reply, results, state, 0}
  end

  def handle_call({:release, response}, _from, state) do
    Enum.each(state.sockets, fn socket ->
      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end)

    {:reply, :ok, %{state | sockets: [], held_requests: []}, 0}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sockets, &:gen_tcp.close/1)
    :gen_tcp.close(state.listener)
  end

  defp read_request(socket, partial) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 2000)
    request = partial <> chunk

    case String.split(request, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length),
          do: request,
          else: read_request(socket, request)

      _ ->
        read_request(socket, request)
    end
  end
end
