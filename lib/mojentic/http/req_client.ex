defmodule Mojentic.HTTP.ReqClient do
  @moduledoc """
  Req-backed implementation of the `Mojentic.HTTP` behaviour.
  """

  @behaviour Mojentic.HTTP
  alias Mojentic.HTTP.WireTrace

  @impl true
  def get(url, headers, opts) do
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    # Mojentic.HTTP promises a binary body; Req would decode JSON into a map.
    case Req.get(url,
           headers: headers,
           decode_body: false,
           receive_timeout: timeout,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        {:ok, %{status_code: status, body: body, headers: flatten_headers(resp_headers)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl true
  def post(url, body, headers, opts) do
    if Keyword.get(opts, :wire_trace) || Keyword.get(opts, :recovery_metadata, false) do
      traced_post(url, body, headers, opts)
    else
      ordinary_post(url, body, headers, opts)
    end
  end

  defp traced_post(url, body, headers, opts) do
    {:ok, stream} =
      post_stream(
        url,
        body,
        headers,
        Keyword.merge(opts, stream_metadata: true, stream_timeout: :idle)
      )

    Enum.reduce(stream, {:ok, %{status_code: nil, headers: [], body: ""}}, fn
      {:headers, status, headers}, {:ok, response} ->
        {:ok, %{response | status_code: status, headers: headers}}

      {kind, chunk}, {:ok, response} when kind in [:data, :http_data] ->
        {:ok, %{response | body: response.body <> chunk}}

      {:error, {:http_response, status, headers, body}}, _ ->
        {:ok, %{status_code: status, headers: headers, body: body}}

      {:error, {:http_response, status, headers, body, cause}}, _ ->
        {:error, {:http_response, status, headers, body, cause}}

      {:error, reason}, {:ok, response} ->
        cause = post_cause(reason)

        if is_nil(response.status_code) do
          {:error, cause}
        else
          {:error, {:http_response, response.status_code, response.headers, response.body, cause}}
        end
    end)
  end

  # Preserve the existing POST cause contract while retaining received evidence.
  defp post_cause(:timeout), do: %Req.TransportError{reason: :timeout}

  defp post_cause(%Finch.TransportError{reason: reason}),
    do: %Req.TransportError{reason: reason}

  defp post_cause(reason), do: reason

  defp ordinary_post(url, body, headers, opts) do
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    case Req.post(url,
           decode_body: Keyword.get(opts, :retry) != false,
           retry: Keyword.get(opts, :retry, :safe_transient),
           redirect: Keyword.get(opts, :redirect, true),
           body: body,
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        resp_body = if is_binary(resp_body), do: resp_body, else: Jason.encode!(resp_body)
        {:ok, %{status_code: status, body: resp_body, headers: flatten_headers(resp_headers)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc """
  Streams a response with an absolute timeout by default.

  Set `stream_timeout: :idle` to apply `recv_timeout` separately to connection
  setup and each wait for received stream data, allowing longer active streams.
  """
  @impl true
  def post_stream(url, body, headers, opts) do
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    stream =
      Stream.resource(
        fn ->
          start_stream(
            url,
            body,
            headers,
            timeout,
            Keyword.get(opts, :stream_timeout, :absolute),
            Keyword.get(opts, :stream_metadata, false),
            Keyword.get(opts, :cancel_ref),
            not is_nil(Keyword.get(opts, :wire_trace)) or
              Keyword.get(opts, :recovery_metadata, false)
          )
        end,
        &next_stream/1,
        &close_stream/1
      )

    stream =
      WireTrace.stream(
        Keyword.get(opts, :wire_trace),
        %{type: :request, method: :post, url: url, headers: headers, body: body},
        stream
      )

    {:ok, stream}
  end

  defp start_stream(url, body, headers, timeout, mode, metadata, cancel, trace) do
    deadline =
      if mode == :idle, do: {:idle, timeout}, else: System.monotonic_time(:millisecond) + timeout

    case Req.post(url,
           body: body,
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: timeout],
           retry: false,
           redirect: false,
           into: :self
         ) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        if metadata,
          do: {:headers, response, {deadline, cancel}},
          else: {:streaming, response, deadline}

      {:ok, response} when trace ->
        {:failed_headers, response, deadline, cancel}

      {:ok, response} ->
        Req.cancel_async_response(response)

        if metadata,
          do: {:error, {:http_response, response.status, flatten_headers(response.headers)}},
          else: {:error, {:http_error, response.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_stream({:failed_headers, response, deadline, cancel}),
    do:
      {[{:headers, response.status, flatten_headers(response.headers)}],
       {:failed_body, response, deadline, cancel, ""}}

  defp next_stream({:failed_body, response, deadline, cancel, body} = state) do
    remaining =
      case deadline do
        {:idle, timeout} -> timeout
        deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
      end

    case receive_stream(state, response.body.ref, remaining, cancel) do
      {:halt, _} ->
        {[{:error, {:http_response, response.status, flatten_headers(response.headers), body}}],
         :done}

      {[{:error, cause}], :done} ->
        {[
           {:error,
            {:http_response, response.status, flatten_headers(response.headers), body, cause}}
         ], :done}

      {events, _} ->
        chunks = for {:data, chunk} <- events, do: chunk

        {Enum.map(chunks, &{:http_data, &1}),
         {:failed_body, response, deadline, cancel, body <> IO.iodata_to_binary(chunks)}}
    end
  end

  defp next_stream({:headers, response, {deadline, cancel}}),
    do:
      {[{:headers, response.status, flatten_headers(response.headers)}],
       {:recovering, response, deadline, cancel}}

  defp next_stream({:recovering, response, {:idle, timeout}, cancel} = state),
    do: receive_stream(state, response.body.ref, timeout, cancel)

  defp next_stream({:error, reason}), do: {[{:error, reason}], :done}
  defp next_stream(:done), do: {:halt, :done}

  defp next_stream({:streaming, response, {:idle, timeout}} = state),
    do: receive_stream(state, response.body.ref, timeout)

  defp next_stream({:streaming, response, deadline} = state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      close_stream(state)
      {[{:error, :timeout}], :done}
    else
      receive_stream(state, response.body.ref, remaining)
    end
  end

  defp receive_stream(state, ref, remaining, cancel \\ nil) do
    response = elem(state, 1)

    receive do
      {:cancel, ^cancel} when not is_nil(cancel) ->
        close_stream(state)
        {[{:error, :cancelled}], :done}

      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          {:ok, [:done]} ->
            {:halt, state}

          {:ok, events} ->
            {Enum.filter(events, &match?({:data, _}, &1)), state}

          {:error, %Finch.TransportError{reason: :timeout}} when elem(state, 0) == :streaming ->
            # Legacy streams expose :timeout for either timer. Metadata streams
            # retain the native exception for explicit recovery cause inspection.
            close_stream(state)
            {[{:error, :timeout}], :done}

          {:error, reason} ->
            close_stream(state)
            {[{:error, reason}], :done}
        end
    after
      remaining ->
        close_stream(state)
        {[{:error, :timeout}], :done}
    end
  end

  defp close_stream({:failed_headers, response, _, _}), do: Req.cancel_async_response(response)
  defp close_stream({:failed_body, response, _, _, _}), do: Req.cancel_async_response(response)
  defp close_stream({:recovering, response, _, _}), do: Req.cancel_async_response(response)
  defp close_stream({:headers, response, _deadline}), do: Req.cancel_async_response(response)
  defp close_stream({:streaming, response, _deadline}), do: Req.cancel_async_response(response)
  defp close_stream(_), do: :ok

  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {key, values} ->
      Enum.map(List.wrap(values), fn value -> {key, value} end)
    end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers
end
