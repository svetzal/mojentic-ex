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

  for winner <- [:finch, :receive_loop] do
    @winner winner
    @tag :stalled_timeout_proof
    test "stalled stream #{@winner} timeout retains the legacy timeout contract" do
      server =
        start_supervised!(
          {Mojentic.TestSupport.ScriptedCompletionServer,
           {self(), [{:stream_hold, "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\npartial"}]}}
        )

      assert_receive {:server_port, port}

      {:ok, stream} =
        ReqClient.post_stream("http://127.0.0.1:#{port}/stream", "{}", [],
          recv_timeout: 100,
          stream_timeout: :idle
        )

      events =
        stream
        |> Stream.map(fn
          {:data, "partial"} = event ->
            # Wait for the actual Finch/socket timeout, rather than injecting one.
            # Requeue it to select notification handling, or drain it to exercise
            # the receive loop's own timeout with the same stalled connection.
            assert_receive {ref, {:error, %Finch.TransportError{reason: :timeout}}} = message,
                           2000

            assert is_tuple(ref)
            if @winner == :finch, do: send(self(), message)
            event

          event ->
            event
        end)
        |> Enum.to_list()

      assert events == [{:data, "partial"}, {:error, :timeout}]
      assert_receive {:wire_request, request}
      assert String.ends_with?(request, "\r\n\r\n{}")
      assert GenServer.call(server, :requests) == [request]
    end
  end

  for winner <- [:finch, :receive_loop] do
    @winner winner
    @tag :stalled_post_boundary
    test "recovery POST #{@winner} timeout retains Req cause and received 200 evidence" do
      server =
        start_supervised!(
          {Mojentic.TestSupport.ScriptedCompletionServer,
           {self(), [{:stream_hold, "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\npartial"}]}}
        )

      assert_receive {:server_port, port}

      trace = fn
        %{type: :response_data} ->
          assert_receive {_ref, {:error, %Finch.TransportError{reason: :timeout}}} = message, 2000
          if @winner == :finch, do: send(self(), message)
          :ok

        _ ->
          :ok
      end

      assert {:error,
              {:http_response, 200, [{"content-length", "999"}], "partial",
               %Req.TransportError{reason: :timeout}}} =
               ReqClient.post("http://127.0.0.1:#{port}/x", "{}", [],
                 retry: false,
                 recv_timeout: 100,
                 recovery_metadata: true,
                 wire_trace: {trace, %{}}
               )

      assert_receive {:wire_request, request}
      assert String.ends_with?(request, "\r\n\r\n{}")
      assert GenServer.call(server, :requests) == [request]
    end
  end

  @tag :stalled_post_boundary
  test "ordinary retries-disabled POST retains Req timeout and sends once" do
    server =
      start_supervised!(
        {Mojentic.TestSupport.ScriptedCompletionServer,
         {self(), [{:stream_hold, "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\npartial"}]}}
      )

    assert_receive {:server_port, port}

    assert {:error, %Req.TransportError{reason: :timeout}} =
             ReqClient.post("http://127.0.0.1:#{port}/x", "{}", [],
               retry: false,
               recv_timeout: 100
             )

    assert_receive {:wire_request, request}
    assert GenServer.call(server, :requests) == [request]
  end

  for metadata <- [false, true] do
    @metadata metadata
    test "legacy non-2xx stream metadata #{@metadata} retains immediate status-only contract" do
      server =
        start_supervised!(
          {Mojentic.TestSupport.ScriptedCompletionServer,
           {self(),
            [
              {:stream_hold,
               "HTTP/1.1 401 Unauthorized\r\nContent-Length: 999\r\nX-Request-ID: frozen-17\r\n\r\npartial"}
            ]}}
        )

      assert_receive {:server_port, port}

      assert {:ok, stream} =
               ReqClient.post_stream("http://127.0.0.1:#{port}/x", "{}", [],
                 stream_metadata: @metadata
               )

      if @metadata do
        assert [{:error, {:http_response, 401, headers}}] = Enum.to_list(stream)
        assert {"x-request-id", "frozen-17"} in headers
      else
        assert [{:error, {:http_error, 401}}] = Enum.to_list(stream)
      end

      assert length(GenServer.call(server, :requests)) == 1
    end
  end

  test "unrelated post with retries disabled retains transport-only interrupted response" do
    start_supervised!(
      {Mojentic.TestSupport.ScriptedCompletionServer,
       {self(), ["HTTP/1.1 401 Unauthorized\r\nContent-Length: 999\r\n\r\npartial"]}}
    )

    assert_receive {:server_port, port}

    assert {:error, %Req.TransportError{reason: :closed}} =
             ReqClient.post("http://127.0.0.1:#{port}/x", "{}", [], retry: false)
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
