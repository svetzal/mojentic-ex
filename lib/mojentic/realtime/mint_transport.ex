defmodule Mojentic.Realtime.MintTransport do
  @moduledoc """
  WebSocket transport backed by Mint.WebSocket.

  Opens a TLS connection, upgrades to WebSocket, and pumps frames in
  a GenServer. Inbound text frames are JSON-decoded and forwarded to
  the subscribed process as `{:realtime_message, map}` messages.
  Connection-level events arrive as `{:realtime_close, reason}` and
  `{:realtime_error, reason}`.

  Outbound payloads are JSON-encoded and sent as a single text frame
  via `send/2`.

  Production implementation of `Mojentic.Realtime.Transport`.
  """

  @behaviour Mojentic.Realtime.Transport

  use GenServer

  alias Mint.HTTP
  alias Mint.WebSocket

  @impl true
  def connect(url, headers, opts \\ []) do
    GenServer.start_link(__MODULE__, {url, headers, opts})
  end

  @impl true
  def send(pid, payload) do
    GenServer.call(pid, {:send, payload})
  end

  @impl true
  def close(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
  end

  @impl true
  def subscribe(pid, subscriber) do
    GenServer.call(pid, {:subscribe, subscriber})
  end

  # GenServer callbacks ------------------------------------------------------

  @impl GenServer
  def init({url, headers, opts}) do
    %URI{scheme: scheme, host: host, path: path, query: query, port: port} = URI.parse(url)
    {http_scheme, ws_scheme} = scheme_pair(scheme)

    path_with_query =
      case query do
        nil -> path || "/"
        q -> (path || "/") <> "?" <> q
      end

    with {:ok, conn} <- HTTP.connect(http_scheme, host, port || default_port(http_scheme), opts),
         {:ok, conn, ref} <- WebSocket.upgrade(ws_scheme, conn, path_with_query, headers) do
      state = %{
        conn: conn,
        websocket: nil,
        request_ref: ref,
        subscriber: nil,
        buffer: []
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:connect_failed, reason}}
      {:error, _conn, reason} -> {:stop, {:upgrade_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  @impl GenServer
  def handle_call({:send, _payload}, _from, %{websocket: nil} = state) do
    {:reply, {:error, :not_open}, state}
  end

  def handle_call({:send, payload}, _from, %{websocket: ws, conn: conn} = state) do
    text = Jason.encode!(payload)

    case WebSocket.encode(ws, {:text, text}) do
      {:ok, ws, data} ->
        case WebSocket.stream_request_body(conn, state.request_ref, data) do
          {:ok, conn} ->
            {:reply, :ok, %{state | conn: conn, websocket: ws}}

          {:error, conn, reason} ->
            {:reply, {:error, reason}, %{state | conn: conn, websocket: ws}}
        end

      {:error, ws, reason} ->
        {:reply, {:error, reason}, %{state | websocket: ws}}
    end
  end

  @impl GenServer
  def handle_info(message, %{conn: conn} = state) do
    case HTTP.stream(conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        state =
          Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)

        {:noreply, state}

      {:error, conn, reason, _responses} ->
        notify_subscriber(state, {:realtime_error, reason})
        {:stop, :normal, %{state | conn: conn}}
    end
  end

  @impl GenServer
  def terminate(_reason, %{subscriber: subscriber}) when is_pid(subscriber) do
    Process.send(subscriber, {:realtime_close, :transport_terminated}, [])
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------

  defp handle_response({:status, ref, _status}, %{request_ref: ref} = state), do: state
  defp handle_response({:headers, ref, _headers}, %{request_ref: ref} = state), do: state

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    case WebSocket.new(state.conn, ref, 101, []) do
      {:ok, conn, ws} -> %{state | conn: conn, websocket: ws}
      {:error, _conn, _reason} = err -> finalize_error(state, err)
    end
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, websocket: ws} = state)
       when ws != nil do
    case WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        Enum.each(frames, &handle_frame(&1, state))
        %{state | websocket: ws}

      {:error, ws, reason} ->
        notify_subscriber(state, {:realtime_error, reason})
        %{state | websocket: ws}
    end
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, map} ->
        notify_subscriber(state, {:realtime_message, map})

      {:error, _} ->
        notify_subscriber(
          state,
          {:realtime_message,
           %{
             "type" => "error",
             "error" => %{"type" => "parse_error", "message" => "invalid json"}
           }}
        )
    end
  end

  defp handle_frame({:close, _code, _reason}, state) do
    notify_subscriber(state, {:realtime_close, :server})
  end

  defp handle_frame(_other, _state), do: :ok

  defp notify_subscriber(%{subscriber: pid}, message) when is_pid(pid) do
    Process.send(pid, message, [])
  end

  defp notify_subscriber(_state, _message), do: :ok

  defp finalize_error(state, {:error, _conn, reason}) do
    notify_subscriber(state, {:realtime_error, reason})
    state
  end

  defp scheme_pair("wss"), do: {:https, :wss}
  defp scheme_pair("ws"), do: {:http, :ws}
  defp scheme_pair(other), do: raise("unsupported scheme: #{inspect(other)}")

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80
end
