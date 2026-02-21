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
        fn ->
          case Req.post(url,
                 body: body,
                 headers: headers,
                 receive_timeout: timeout,
                 connect_options: [timeout: timeout],
                 into: :self
               ) do
            {:ok, resp} ->
              {:streaming, resp}

            {:error, reason} ->
              {:error, reason}
          end
        end,
        fn
          {:error, reason} ->
            {[{:error, reason}], :done}

          :done ->
            {:halt, :done}

          {:streaming, resp} ->
            receive do
              {ref, {:data, data}} when ref == resp.body ->
                {[{:data, data}], {:streaming, resp}}

              {ref, :done} when ref == resp.body ->
                {:halt, :done}
            after
              timeout ->
                {[{:error, :timeout}], :done}
            end
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  defp flatten_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {key, values} ->
      Enum.map(List.wrap(values), fn value -> {key, value} end)
    end)
  end

  defp flatten_headers(headers) when is_list(headers), do: headers
end
