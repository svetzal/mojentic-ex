defmodule Mojentic.HTTP.ReqClientTest do
  # These real-socket timeout checks need the scheduler without concurrent tests.
  use ExUnit.Case, async: false

  alias Mojentic.HTTP.ReqClient

  # Mojentic.HTTP promises a binary body. Req decodes JSON responses by
  # default, so these tests use a real socket and a JSON content type.

  test "get returns a JSON response body as the raw binary" do
    port = serve_json(~s({"data":[{"id":"a-model"}]}))

    assert {:ok, %{status_code: 200, body: body}} =
             ReqClient.get("http://127.0.0.1:#{port}/v1/models", [], recv_timeout: 2000)

    assert body == ~s({"data":[{"id":"a-model"}]})
  end

  test "post returns a JSON response body as a binary" do
    port = serve_json(~s({"ok":true}))

    assert {:ok, %{status_code: 200, body: body}} =
             ReqClient.post("http://127.0.0.1:#{port}/v1/x", "{}", [], recv_timeout: 2000)

    assert Jason.decode!(body) == %{"ok" => true}
  end

  test "idle stream timeout allows consumption beyond its initial timeout" do
    alias Mojentic.TestSupport.ChunkedHTTPServer
    start_supervised!({ChunkedHTTPServer, {self(), ["one", "two"], false, 200}})
    assert_receive {:port, port}

    {:ok, stream} =
      ReqClient.post_stream("http://127.0.0.1:#{port}/stream", "{}", [],
        recv_timeout: 100,
        stream_timeout: :idle
      )

    events =
      Enum.to_list(
        Stream.map(stream, fn event ->
          receive do
            :unused -> :ok
          after
            150 -> :ok
          end

          event
        end)
      )

    assert Enum.all?(events, &match?({:data, _}, &1))
    assert Enum.map_join(events, fn {:data, text} -> text end) == "onetwo"
  end

  test "idle stream timeout still cancels a stalled response" do
    alias Mojentic.TestSupport.ChunkedHTTPServer
    start_supervised!({ChunkedHTTPServer, {self(), ["partial"], true, 200}})
    assert_receive {:port, port}

    {:ok, stream} =
      ReqClient.post_stream("http://127.0.0.1:#{port}/stream", "{}", [],
        recv_timeout: 100,
        stream_timeout: :idle
      )

    assert [{:data, "partial"}, {:error, :timeout}] = Enum.to_list(stream)
    assert_receive {:cancel_result, {:error, :closed}}, 2000
  end

  defp serve_json(json) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2000)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 2000)

      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
        Integer.to_string(byte_size(json)),
        "\r\nConnection: close\r\n\r\n",
        json
      ])

      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    port
  end
end
