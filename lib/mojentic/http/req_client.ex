defmodule Mojentic.HTTP.ReqClient do
  @moduledoc """
  Req-backed implementation of the `Mojentic.HTTP` behaviour.
  """

  @behaviour Mojentic.HTTP

  @impl true
  def get(url, headers, opts) do
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    case Req.get(url,
           headers: headers,
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
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    case Req.post(url,
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

  @impl true
  def post_stream(url, body, headers, opts) do
    timeout = Keyword.get(opts, :recv_timeout, 30_000)

    stream =
      Stream.resource(
        fn -> start_stream(url, body, headers, timeout) end,
        &next_stream/1,
        &close_stream/1
      )

    {:ok, stream}
  end

  defp start_stream(url, body, headers, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

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
        {:streaming, response, deadline}

      {:ok, response} ->
        Req.cancel_async_response(response)
        {:error, {:http_error, response.status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_stream({:error, reason}), do: {[{:error, reason}], :done}
  defp next_stream(:done), do: {:halt, :done}

  defp next_stream({:streaming, response, deadline} = state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      close_stream(state)
      {[{:error, :timeout}], :done}
    else
      receive_stream(state, response.body.ref, remaining)
    end
  end

  defp receive_stream({:streaming, response, _deadline} = state, ref, remaining) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(response, message) do
          {:ok, [:done]} ->
            {:halt, state}

          {:ok, events} ->
            {Enum.filter(events, &match?({:data, _}, &1)), state}

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

  defp close_stream({:streaming, response, _deadline}), do: Req.cancel_async_response(response)
  defp close_stream(_), do: :ok

  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {key, values} ->
      Enum.map(List.wrap(values), fn value -> {key, value} end)
    end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers
end
