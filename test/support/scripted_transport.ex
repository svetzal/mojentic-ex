defmodule Mojentic.TestSupport.ScriptedTransport do
  @moduledoc """
  In-process Req adapter. HTTP-shaped response fixtures describe status, headers
  and body fragments; no HTTP connection is made. Request transcripts render
  the prepared request observed by the adapter, before protocol framing.
  """
  use GenServer

  def start_link({owner, responses}), do: start_link({owner, responses, 0})
  def start_link({owner, responses, port}), do: start_link({owner, responses, port, nil})
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init({owner, responses, requested_port, _}) do
    Process.flag(:trap_exit, true)

    port =
      if requested_port == 0,
        do: 1024 + rem(System.unique_integer([:positive]), 60_000),
        else: requested_port

    previous = Req.default_options()
    transports = Application.get_env(:mojentic, :test_transports, %{})
    Application.put_env(:mojentic, :test_transports, Map.put(transports, port, self()))
    Req.default_options(adapter: __MODULE__, retry_delay: fn _ -> 0 end)
    send(owner, {:transport_id, port})

    {:ok,
     %{
       owner: owner,
       responses: responses,
       requests: [],
       active: %{},
       closed: MapSet.new(),
       port: port,
       previous: previous
     }}
  end

  def run(request) do
    transports = Application.fetch_env!(:mojentic, :test_transports)
    transport = Map.fetch!(transports, request.url.port)
    ref = make_ref()
    transcript = transcript(request)
    result = GenServer.call(transport, {:dispatch, self(), ref, transcript})

    reply(request, transport, ref, result)
  end

  defp reply(request, _transport, _ref, {:error, reason}),
    do: {request, %Req.TransportError{reason: reason}}

  defp reply(request, transport, ref, {status, headers, chunks, held}) do
    if request.into == :self do
      Enum.each(chunks, &send(self(), {ref, {:data, &1}}))

      case held do
        false -> send(self(), {ref, :done})
        {:error, reason} -> send(self(), {ref, {:error, reason}})
        true -> :ok
      end

      body = %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: fn
          ^ref, {^ref, {:error, reason}} -> {:error, reason}
          ^ref, {^ref, :done} -> {:ok, [:done]}
          ^ref, {^ref, {:data, chunk}} -> {:ok, [data: chunk]}
        end,
        cancel_fun: fn ^ref -> GenServer.call(transport, {:close, ref}) end
      }

      {request, Req.Response.new(status: status, headers: headers, body: body)}
    else
      case held do
        {:error, %{reason: reason}} ->
          {request, %Req.TransportError{reason: reason}}

        _ ->
          {request,
           Req.Response.new(status: status, headers: headers, body: IO.iodata_to_binary(chunks))}
      end
    end
  end

  defp transcript(request) do
    headers =
      Enum.flat_map(request.headers, fn {name, values} ->
        Enum.map(List.wrap(values), &"#{name}: #{&1}")
      end)

    path = request.url.path || "/"
    path = if request.url.query, do: path <> "?" <> request.url.query, else: path

    Enum.join([String.upcase(to_string(request.method)) <> " #{path} HTTP/1.1" | headers], "\r\n") <>
      "\r\n\r\n" <> IO.iodata_to_binary(request.body || "")
  end

  @impl true
  def handle_call({:dispatch, pid, ref, request}, from, state) do
    [response | rest] = state.responses
    Process.monitor(pid)
    send(state.owner, {:transport_request, request})

    state = %{
      state
      | responses: rest,
        requests: state.requests ++ [request],
        active: Map.put(state.active, ref, {pid, request, from, chunked?(response)})
    }

    case response do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      "" ->
        {:reply, {:error, :closed}, state}

      {:stream_error, response, reason} ->
        {status, headers, chunks, _} = response(response)

        {:reply,
         {status, headers, chunks,
          {:error,
           %Finch.TransportError{reason: reason, source: %Mint.TransportError{reason: reason}}}},
         state}

      :hold ->
        {:noreply, state}

      {mode, response} when mode in [:stream_hold, :stream_half_close] ->
        {status, headers, chunks, outcome} = response(response)
        send(state.owner, {:held_response_sent, request, response})

        {:reply,
         {status, headers, chunks,
          if(mode == :stream_hold and not complete_body?(response), do: true, else: outcome)},
         state}

      response ->
        {:reply, response(response), state}
    end
  end

  def handle_call(:id, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  def handle_call({:response_state, request}, _from, state) do
    {:reply, if(MapSet.member?(state.closed, request), do: :closed, else: :open), state}
  end

  def handle_call(:closed_responses, _from, state),
    do: {:reply, Enum.map(state.closed, fn _ -> :closed end), state}

  def handle_call({:close, ref}, _from, state) do
    case Map.get(state.active, ref) do
      nil ->
        {:reply, :ok, state}

      {_pid, request, _, _} ->
        send(state.owner, {:transport_closed, request})
        {:reply, :ok, %{state | closed: MapSet.put(state.closed, request)}}
    end
  end

  # Data and EOF can be released separately so a public consumer can
  # acknowledge delivery before the adapter reports a disconnect.
  def handle_call({:release_data, response}, _from, state) do
    Enum.each(state.active, fn {ref, {pid, _request, _from, chunked}} ->
      {data, _done} = if chunked, do: chunks(response), else: {[response], false}
      Enum.each(data, &send(pid, {ref, {:data, &1}}))
    end)

    {:reply, :ok, state}
  end

  def handle_call({:release, response}, _from, state) do
    Enum.each(state.active, fn {ref, {pid, _request, from, chunked}} ->
      if String.starts_with?(response, "HTTP/") do
        GenServer.reply(from, response(response))
      else
        {chunks, done} = if chunked, do: chunks(response), else: {[response], true}
        Enum.each(chunks, &send(pid, {ref, {:data, &1}}))
        send(pid, {ref, if(done, do: :done, else: {:error, closed_error()})})
      end
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    closed =
      Enum.reduce(state.active, state.closed, fn
        {_ref, {^pid, request, _, _}}, closed ->
          send(state.owner, {:transport_closed, request})
          MapSet.put(closed, request)

        _, closed ->
          closed
      end)

    {:noreply, %{state | closed: closed}}
  end

  @impl true
  def terminate(_, state) do
    transports = Application.get_env(:mojentic, :test_transports, %{})
    Application.put_env(:mojentic, :test_transports, Map.delete(transports, state.port))
    Req.default_options(state.previous)
  end

  defp response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status | headers] = String.split(head, "\r\n")
    status = status |> String.split() |> Enum.at(1) |> String.to_integer()

    headers =
      Enum.map(headers, fn header ->
        [name, value] = String.split(header, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    {body, done} =
      if {"transfer-encoding", "chunked"} in headers,
        do: chunks(body),
        else: {[body], not truncated?(headers, body)}

    {status, headers, body, if(done, do: false, else: {:error, closed_error()})}
  end

  defp complete_body?(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)

    case Regex.run(~r/content-length: (\d+)/i, head) do
      [_, length] -> byte_size(body) >= String.to_integer(length)
      nil -> chunked?(response) and String.ends_with?(body, "0\r\n\r\n")
    end
  end

  defp chunked?({_, response}), do: chunked?(response)
  defp chunked?({_, response, _}), do: chunked?(response)

  defp chunked?(response) when is_binary(response),
    do: String.contains?(String.downcase(response), "transfer-encoding: chunked")

  defp chunked?(_), do: false

  defp closed_error,
    do: %Finch.TransportError{reason: :closed, source: %Mint.TransportError{reason: :closed}}

  defp truncated?(headers, body) do
    case List.keyfind(headers, "content-length", 0) do
      {_, length} -> byte_size(body) < String.to_integer(length)
      nil -> false
    end
  end

  defp chunks(""), do: {[], false}
  defp chunks("0\r\n\r\n"), do: {[], true}

  defp chunks(body) do
    [size, rest] = String.split(body, "\r\n", parts: 2)
    size = String.to_integer(size, 16)
    <<chunk::binary-size(size), "\r\n", rest::binary>> = rest
    {chunks, done} = chunks(rest)
    {[chunk | chunks], done}
  end
end
