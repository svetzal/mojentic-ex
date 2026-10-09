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
    {:ok, %{owner: owner, listener: listener, responses: responses, requests: []}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    case :gen_tcp.accept(state.listener, 50) do
      {:ok, socket} ->
        request = read_request(socket, "")
        send(state.owner, {:wire_request, request})
        [response | rest] = state.responses
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        {:noreply, %{state | requests: state.requests ++ [request], responses: rest}, 0}

      {:error, :timeout} ->
        {:noreply, state, 0}
    end
  end

  @impl true
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state, 0}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.listener)

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
