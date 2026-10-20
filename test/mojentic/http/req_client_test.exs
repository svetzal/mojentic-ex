defmodule Mojentic.HTTP.ReqClientTest do
  # Req adapter defaults are scoped to these serial tests.
  use ExUnit.Case, async: false

  alias Mojentic.HTTP.ReqClient
  alias Mojentic.TestSupport.{ContextWindowContract, ScriptedTransport}

  @external_resource "test/contracts/context_window_v1.json"
  @response_cases Enum.filter(ContextWindowContract.contract()["cases"], fn row ->
                    row["provider"] == "ollama" and
                      (row["name"] in ["qwen4_exp", "reject-json-string-object"] or
                         String.starts_with?(row["name"], "malformed-"))
                  end)

  for row <- @response_cases,
      {mode, opts} <- [ordinary: [], no_retry: [retry: false], traced: [recovery_metadata: true]] do
    @row row
    @opts opts
    test "context-window-v1 POST #{mode} preserves exact #{row["name"]} response bytes" do
      server =
        start_supervised!({ScriptedTransport, {self(), [ContextWindowContract.response(@row)]}})

      assert_receive {:transport_id, port}

      assert {:ok, %{status_code: 200, body: body}} =
               ReqClient.post("http://127.0.0.1:#{port}/api/show", "{}", [], @opts)

      assert body == @row["response"]
      assert [_request] = GenServer.call(server, :requests)
    end
  end

  # Mojentic.HTTP promises a binary body. Req decodes JSON responses by
  # default, so the transport fixtures retain a JSON content type.

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

  test "closing one stream leaves another stream at the same origin cancellable" do
    response = "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\npartial"

    server =
      start_supervised!(
        {Mojentic.TestSupport.ScriptedTransport,
         {self(), [{:stream_hold, response}, {:stream_hold, response}]}}
      )

    assert_receive {:transport_id, port}
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()
    cancel = make_ref()
    url = "http://127.0.0.1:#{port}/stream"

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, stream} =
          ReqClient.post_stream(url, "held", [],
            recv_timeout: 2000,
            stream_timeout: :idle,
            stream_metadata: true,
            cancel_ref: cancel
          )

        stream
        |> Stream.map(fn
          {:data, "partial"} = event ->
            send(owner, :held_stream_ready)
            assert_receive :resume, 2000
            event

          event ->
            event
        end)
        |> Enum.to_list()
      end)

    assert_receive :held_stream_ready, 2000
    assert_receive {:transport_request, held_request}

    {:ok, stream} = ReqClient.post_stream(url, "halted", [], recv_timeout: 2000)
    assert Enum.take(stream, 1) == [{:data, "partial"}]
    assert_receive {:transport_request, halted_request}
    assert GenServer.call(server, {:response_state, halted_request}) == :closed

    send(task.pid, {:cancel, cancel})
    send(task.pid, :resume)

    assert [{:headers, 200, _}, {:data, "partial"}, {:error, :cancelled}] =
             Task.await(task, 2000)

    assert GenServer.call(server, {:response_state, held_request}) == :closed
    assert GenServer.call(server, :requests) == [held_request, halted_request]
  end

  for metadata <- [false, true] do
    @metadata metadata
    test "legacy non-2xx stream metadata #{@metadata} retains immediate status-only contract" do
      server =
        start_supervised!(
          {Mojentic.TestSupport.ScriptedTransport,
           {self(),
            [
              {:stream_hold,
               "HTTP/1.1 401 Unauthorized\r\nContent-Length: 999\r\nX-Request-ID: frozen-17\r\n\r\npartial"}
            ]}}
        )

      assert_receive {:transport_id, port}

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
      {Mojentic.TestSupport.ScriptedTransport,
       {self(), ["HTTP/1.1 401 Unauthorized\r\nContent-Length: 999\r\n\r\npartial"]}}
    )

    assert_receive {:transport_id, port}

    assert {:error, %Req.TransportError{reason: :closed}} =
             ReqClient.post("http://127.0.0.1:#{port}/x", "{}", [], retry: false)
  end

  for mode <- [:absolute, :idle] do
    @mode mode
    test "zero #{@mode} timeout distinguishes queued data from an expired absolute deadline" do
      transport =
        start_supervised!(
          {ScriptedTransport, {self(), [{:stream_hold, "HTTP/1.1 200 OK\r\n\r\npartial"}]}}
        )

      assert_receive {:transport_id, id}

      {:ok, stream} =
        ReqClient.post_stream("http://example.test:#{id}/stream", "{}", [],
          recv_timeout: 0,
          stream_timeout: @mode
        )

      expected =
        if @mode == :idle,
          do: [{:data, "partial"}, {:error, :timeout}],
          else: [{:error, :timeout}]

      assert Enum.to_list(stream) == expected
      assert_receive {:transport_request, request}
      assert GenServer.call(transport, {:response_state, request}) == :closed
      assert GenServer.call(transport, :requests) == [request]
    end
  end

  for status <- [200, 503] do
    @status status
    test "absolute deadline expires after explicit clock advance for HTTP #{@status}" do
      Mojentic.TestSupport.Clock.install()

      transport =
        start_supervised!(
          {ScriptedTransport,
           {self(), [{:stream_hold, "HTTP/1.1 #{@status} Response\r\n\r\npartial"}]}}
        )

      assert_receive {:transport_id, id}

      {:ok, stream} =
        ReqClient.post_stream("http://example.test:#{id}/stream", "{}", [],
          recv_timeout: 1000,
          recovery_metadata: true
        )

      events =
        Enum.map(stream, fn event ->
          if event in [{:data, "partial"}, {:http_data, "partial"}] do
            Mojentic.TestSupport.Clock.advance(1000)
            # A queued end must not mask the expired successful-stream deadline.
            if @status == 200, do: GenServer.call(transport, {:release, ""})
          end

          event
        end)

      assert Mojentic.TestSupport.Clock.last_read() == 1000

      if @status == 200 do
        assert events == [{:data, "partial"}, {:error, :timeout}]
      else
        assert events == [
                 {:headers, 503, []},
                 {:http_data, "partial"},
                 {:error, {:http_response, 503, [], "partial", :timeout}}
               ]
      end

      assert_receive {:transport_request, request}
      assert GenServer.call(transport, {:response_state, request}) == :closed
      assert GenServer.call(transport, :requests) == [request]
    end
  end

  defp serve_json(json) do
    response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" <> json
    start_supervised!({ScriptedTransport, {self(), [response]}})
    assert_receive {:transport_id, id}
    id
  end
end
