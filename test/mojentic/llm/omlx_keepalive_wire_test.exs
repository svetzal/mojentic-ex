defmodule Mojentic.LLM.OMLXKeepaliveWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, Message}
  alias Mojentic.LLM.Gateways.OMLX
  alias Mojentic.TestSupport.ScriptedCompletionServer

  @moduletag :omlx_keepalive_contract
  @entrypoints [:events, :legacy, :broker_events, :broker_legacy, :session]
  @empty %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)
    old_host = System.get_env("OMLX_HOST")
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)
      if old_host, do: System.put_env("OMLX_HOST", old_host), else: System.delete_env("OMLX_HOST")
    end)

    :ok
  end

  for entrypoint <- @entrypoints,
      layout <- [:coalesced, :fragmented_before, :fragmented_between, :fragmented_after] do
    @entrypoint entrypoint
    @layout layout
    test "#{entrypoint} #{@layout} keepalives preserve exact output metadata and progress" do
      wire = successful_body()

      scripted =
        if @layout != :coalesced do
          [headers, _] = String.split(response(wire), "\r\n\r\n", parts: 2)
          {:stream_hold, headers <> "\r\n\r\n" <> binary_part(wire, 0, split_at(wire, @layout))}
        else
          response(wire)
        end

      server = server([scripted])
      config = config()
      {output, handle} = consume(server, @entrypoint, config, wire, @layout)
      assert_success(output, @entrypoint)
      assert_session(handle, :success)
      lifecycle = lifecycle()
      assert Enum.map(lifecycle, & &1.type) == [:attempt_started, :attempt_succeeded]
      assert_lifecycle(lifecycle, 1)

      assert List.last(lifecycle).metadata.progress == %{
               headers_received: true,
               raw_bytes: byte_size(wire),
               observed: %{@empty | content: true},
               delivered: %{@empty | content: true}
             }

      assert_requests(server, @entrypoint, 1)
    end
  end

  for entrypoint <- @entrypoints,
      decision <- [:allow, :reject, :undecided, :raise, :no_hook, :default_attempts] do
    @entrypoint entrypoint
    @decision decision
    test "#{entrypoint} keepalive-only truncation obeys #{@decision} admission without ghost progress" do
      wire = keepalive()
      server = server([truncated(wire), response(successful_body())])
      owner = self()

      opts =
        case @decision do
          :allow ->
            [
              admission: fn context ->
                send(owner, {:admission, context})
                :allow
              end
            ]

          :reject ->
            [admission: fn _ -> :reject end]

          :undecided ->
            [admission: fn _ -> nil end]

          :raise ->
            [admission: fn _ -> raise "private-admission" end]

          :no_hook ->
            []

          :default_attempts ->
            [max_attempts: 1, admission: fn _ -> flunk("unexpected admission") end]
        end

      {stream, handle} = invoke(@entrypoint, config(opts))
      output = Enum.to_list(stream)
      lifecycle = lifecycle()
      failure = Enum.find(lifecycle, &(&1.type == :attempt_failed)).metadata

      assert failure.progress == %{
               headers_received: true,
               raw_bytes: byte_size(wire),
               observed: @empty,
               delivered: @empty
             }

      assert failure.phase == :streaming
      assert failure.category == :transport
      assert failure.retry_eligible
      assert failure.acceptance == :unknown
      assert failure.provider_request_id == "keepalive-contract-v1"
      assert failure.operation == operation(@entrypoint)

      if @decision == :allow do
        assert_success(output, @entrypoint)
        assert_session(handle, :success)

        assert Enum.map(lifecycle, & &1.type) == [
                 :attempt_started,
                 :attempt_failed,
                 :admission_pending,
                 :admission_allowed,
                 :backoff_started,
                 :retry_started,
                 :attempt_started,
                 :attempt_succeeded
               ]

        assert_receive {:admission, context}
        assert context.progress == failure.progress
        assert context.failure == failure
        assert context.next_attempt == 2
        assert context.previous_attempt_id == failure.attempt_id
        backoff = Enum.find(lifecycle, &(&1.type == :backoff_started))
        assert backoff.metadata.delay_ms == 0
        assert_requests(server, @entrypoint, 2)
        assert_lifecycle(lifecycle, 2)
      else
        assert [{:error, error}] = output
        assert_session(handle, {:error, error})

        expected =
          case @decision do
            :reject -> :rejected
            value when value in [:undecided, :raise] -> :admission_no_decision
            :no_hook -> :admission_required
            :default_attempts -> :not_granted
          end

        assert error.reason == :transport_failure
        assert error.resend_permission == expected
        assert Enum.map(lifecycle, & &1.type) == stopped_lifecycle(@decision)
        assert error.progress == failure.progress
        assert error.history == [Map.delete(failure, :history)]
        refute inspect(error) =~ "private-admission"
        assert_requests(server, @entrypoint, 1)
        assert_lifecycle(lifecycle, 1)
      end
    end
  end

  for entrypoint <- @entrypoints, semantic <- [:content, :reasoning, :tools] do
    @entrypoint entrypoint
    @semantic semantic
    test "#{entrypoint} real #{@semantic} before keepalive truncation forbids replay" do
      delta =
        case @semantic do
          :content ->
            %{content: "real-text"}

          :reasoning ->
            %{reasoning_content: "real-thought"}

          :tools ->
            %{
              tool_calls: [
                %{index: 0, id: "real-call", function: %{name: "lookup", arguments: "{"}}
              ]
            }
        end

      wire = keepalive() <> sse(%{model: "real-model", choices: [%{delta: delta}]}) <> keepalive()
      server = server([truncated(wire), response(successful_body())])

      {stream, handle} =
        invoke(@entrypoint, config(admission: fn _ -> flunk("semantic replay") end))

      output = Enum.to_list(stream)

      expected_prefix =
        case {@entrypoint, @semantic} do
          {entry, :content} when entry in [:events, :legacy, :broker_events] ->
            [content: "real-text"]

          {_, :content} ->
            ["real-text"]

          {entry, :reasoning} when entry in [:legacy, :broker_legacy, :session] ->
            [thinking: "real-thought"]

          _ ->
            []
        end

      assert Enum.drop(output, -1) == expected_prefix
      assert {:error, error} = List.last(output)
      assert error.reason == :stream_interrupted
      refute error.retry_eligible

      observed = observed(@semantic)
      delivered = delivered(@semantic, @entrypoint)

      assert error.progress == %{
               headers_received: true,
               raw_bytes: byte_size(wire),
               observed: observed,
               delivered: delivered
             }

      assert_session(handle, {:error, error})
      lifecycle = lifecycle()
      assert Enum.map(lifecycle, & &1.type) == [:attempt_started, :attempt_failed, :exhausted]
      assert_lifecycle(lifecycle, 1)
      assert_requests(server, @entrypoint, 1)
    end
  end

  for mode <- [:events, :legacy] do
    @mode mode
    test "#{mode} capture failure on keepalive retains raw bytes without semantic progress" do
      wire = keepalive()
      server = server([truncated(wire)])

      config =
        config(
          trace_observer: fn
            %{type: :response_data} -> :failed
            _ -> :ok
          end
        )

      {stream, _} = invoke(@mode, config)
      assert [{:error, error}] = Enum.to_list(stream)
      assert error.reason == :capture_failed

      assert error.progress == %{
               headers_received: true,
               raw_bytes: byte_size(wire),
               observed: @empty,
               delivered: @empty
             }

      assert_requests(server, @mode, 1)
    end
  end

  for mode <- [:events, :legacy] do
    @mode mode
    test "#{mode} recovery-disabled oMLX keeps legacy keepalive semantics" do
      server = server([response(successful_body())])
      {stream, _} = invoke(@mode, CompletionConfig.new())
      assert_success(Enum.to_list(stream), @mode)
      assert lifecycle() == []
      assert_requests(server, @mode, 1)
    end

    test "#{mode} minimal keepalive cannot supply completion evidence" do
      wire = sse(%{model: "keepalive"}) <> "data: [DONE]\n\n"
      server = server([response(wire)])
      {stream, _} = invoke(@mode, config())
      assert [{:error, error}] = Enum.to_list(stream)
      assert error.category == :protocol

      assert error.progress == %{
               headers_received: true,
               raw_bytes: byte_size(wire),
               observed: @empty,
               delivered: @empty
             }

      assert_requests(server, @mode, 1)
    end
  end

  test "event stream preserves non-data SSE fields around keepalives" do
    wire = "event: completion\nid: fixture\n: comment\n" <> successful_body()
    server = server([response(wire)])
    {stream, _} = invoke(:events, config())
    assert_success(Enum.to_list(stream), :events)
    assert_requests(server, :events, 1)
  end

  defp stopped_lifecycle(:default_attempts), do: [:attempt_started, :attempt_failed, :exhausted]

  defp stopped_lifecycle(:no_hook),
    do: [:attempt_started, :attempt_failed, :admission_required, :exhausted]

  defp stopped_lifecycle(:reject),
    do: [:attempt_started, :attempt_failed, :admission_pending, :admission_rejected, :exhausted]

  defp stopped_lifecycle(_),
    do: [
      :attempt_started,
      :attempt_failed,
      :admission_pending,
      :admission_no_decision,
      :exhausted
    ]

  defp observed(semantic),
    do: %{
      @empty
      | content: semantic == :content,
        reasoning: semantic == :reasoning,
        tool_fragments: if(semantic == :tools, do: 1, else: 0)
    }

  defp delivered(semantic, entrypoint),
    do: %{
      @empty
      | content: semantic == :content,
        reasoning: semantic == :reasoning and entrypoint in [:legacy, :broker_legacy, :session]
    }

  defp config(opts \\ []) do
    owner = self()

    CompletionConfig.new(
      recovery:
        Keyword.merge(
          [
            max_attempts: 2,
            base_delay: 0,
            sleeper: fn _ -> :ok end,
            observer: fn event -> send(owner, {:lifecycle, event}) end,
            trace_observer: fn event ->
              send(owner, {:trace, event})
              :ok
            end
          ],
          opts
        )
    )
  end

  defp invoke(:events, config),
    do: {OMLX.complete_stream_events("requested-model", messages(), config), nil}

  defp invoke(:legacy, config),
    do: {OMLX.complete_stream("requested-model", messages(), nil, config), nil}

  defp invoke(:broker_events, config),
    do:
      {Broker.generate_stream_events(Broker.new("requested-model", OMLX), messages(), config),
       nil}

  defp invoke(:broker_legacy, config),
    do:
      {Broker.generate_stream(Broker.new("requested-model", OMLX), messages(), nil, config), nil}

  defp invoke(:session, config) do
    session = ChatSession.new(Broker.new("requested-model", OMLX), system_prompt: "prior-system")

    {:ok, stream, handle} =
      ChatSession.send_stream(session, "user-input", recovery: config.recovery)

    {stream, {handle, session}}
  end

  defp consume(_server, entrypoint, config, _wire, :coalesced) do
    {stream, handle} = invoke(entrypoint, config)
    {Enum.to_list(stream), handle}
  end

  defp consume(server, entrypoint, config, wire, layout) do
    # Hold inside a keepalive JSON frame. Waiting for the real Req body trace
    # proves the first fragment arrived before the remainder is released.
    split = split_at(wire, layout)
    <<first::binary-size(split), rest::binary>> = wire
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {stream, handle} = invoke(entrypoint, config)
        {Enum.to_list(stream), handle}
      end)

    assert_receive {:trace, %{type: :response_data, body: ^first}}, 3000
    assert :ok = GenServer.call(server, {:release, rest})
    Task.await(task, 3000)
  end

  defp split_at(wire, layout) do
    index =
      case layout do
        :fragmented_before -> 0
        :fragmented_between -> 1
        :fragmented_after -> 2
      end

    {offset, _} = wire |> :binary.matches(keepalive()) |> Enum.at(index)
    offset + 18
  end

  defp assert_success(output, entrypoint) when entrypoint in [:events, :broker_events] do
    assert output == [
             content: "first",
             content: "second",
             completed: %{
               finish_reason: "stop",
               provider_model: "real-model",
               usage: %{"total_tokens" => 7},
               metadata: nil
             }
           ]
  end

  defp assert_success(output, :legacy),
    do: assert(output == [content: "first", content: "second"])

  defp assert_success(output, _), do: assert(output == ["first", "second"])

  defp assert_session(nil, _), do: :ok

  defp assert_session({handle, original}, :success) do
    updated = ChatSession.finalize_stream(handle)

    assert Enum.map(ChatSession.messages(updated), & &1.message) ==
             messages() ++ [Message.assistant("firstsecond")]

    assert Enum.map(ChatSession.messages(original), & &1.message) == [
             Message.system("prior-system")
           ]
  end

  defp assert_session({handle, original}, {:error, error}) do
    assert ChatSession.finalize_stream(handle) == {:error, error}

    assert Enum.map(ChatSession.messages(original), & &1.message) == [
             Message.system("prior-system")
           ]
  end

  defp assert_lifecycle(events, attempts) do
    starts = Enum.filter(events, &(&1.type == :attempt_started))
    assert Enum.map(starts, & &1.metadata.wire_attempt) == Enum.to_list(1..attempts)
    assert length(Enum.uniq(Enum.map(starts, & &1.metadata.attempt_id))) == attempts
    assert length(Enum.uniq(Enum.map(starts, & &1.metadata.logical_request_id))) == 1

    for event <- events, event.type != :retry_started do
      assert Enum.any?(
               starts,
               &(Map.take(&1.metadata, [:attempt_id, :logical_request_id, :wire_attempt]) ==
                   Map.take(event.metadata, [:attempt_id, :logical_request_id, :wire_attempt]))
             )
    end
  end

  defp assert_requests(server, entrypoint, attempts) do
    requests = GenServer.call(server, :requests)
    assert length(requests) == attempts
    assert length(Enum.uniq(requests)) == 1
    request = hd(requests)
    assert String.starts_with?(request, "POST /v1/chat/completions HTTP/1.1\r\n")
    [_, encoded] = String.split(request, "\r\n\r\n", parts: 2)
    payload = Jason.decode!(encoded)

    expected = %{
      "model" => "requested-model",
      "messages" => [
        %{"role" => "system", "content" => "prior-system"},
        %{"role" => "user", "content" => "user-input"}
      ],
      "stream" => true
    }

    expected =
      if entrypoint in [:events, :broker_events],
        do: Map.put(expected, "stream_options", %{"include_usage" => true}),
        else: expected

    assert payload == expected
    for _ <- 1..attempts, do: assert_receive({:wire_request, ^request})
    refute_receive {:wire_request, _}
  end

  defp messages, do: [Message.system("prior-system"), Message.user("user-input")]

  defp operation(entrypoint) when entrypoint in [:events, :broker_events],
    do: :complete_stream_events

  defp operation(_), do: :complete_stream

  defp lifecycle do
    receive do
      {:lifecycle, event} -> [event | lifecycle()]
    after
      0 -> []
    end
  end

  defp server(responses) do
    server = start_supervised!({ScriptedCompletionServer, {self(), responses}})
    assert_receive {:server_port, port}
    System.put_env("OMLX_HOST", "http://127.0.0.1:#{port}")
    server
  end

  defp sse(frame), do: "data: #{Jason.encode!(frame)}\n\n"

  defp keepalive do
    sse(%{
      model: "keepalive",
      choices: [
        %{
          delta: %{
            content: "ghost",
            reasoning_content: "ghost",
            tool_calls: [%{index: 99, function: %{name: "ghost", arguments: "{}"}}]
          },
          finish_reason: "stop"
        }
      ],
      usage: %{total_tokens: 999}
    })
  end

  defp successful_body do
    keepalive() <>
      sse(%{model: "real-model", choices: [%{delta: %{content: "first"}}]}) <>
      keepalive() <>
      sse(%{
        choices: [%{delta: %{content: "second"}, finish_reason: "stop"}],
        usage: %{total_tokens: 7}
      }) <>
      keepalive() <> "data: [DONE]\n\n"
  end

  defp response(body),
    do:
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\nX-Request-ID: keepalive-contract-v1\r\n\r\n#{body}"

  defp truncated(body),
    do:
      String.replace(
        response(body),
        "Content-Length: #{byte_size(body)}",
        "Content-Length: #{byte_size(body) + 100}"
      )
end
