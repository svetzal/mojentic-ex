defmodule Mojentic.LLM.StreamRecoveryWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.ScriptedCompletionServer

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
    keys = ["OPENAI_API_ENDPOINT", "OPENAI_API_KEY", "OLLAMA_HOST", "OMLX_HOST", "OMLX_API_KEY"]
    old = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)

      Enum.each(old, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "delivered content interrupts through real Req without replay or successful terminal" do
    frame =
      "data: " <> Jason.encode!(%{choices: [%{delta: %{content: "sentinel-output"}}]}) <> "\n\n"

    response =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(frame) + 100}\r\nConnection: close\r\n\r\n#{frame}"

    server = start_supervised!({ScriptedCompletionServer, {self(), [response]}})
    assert_receive {:server_port, port}
    System.put_env("OPENAI_API_ENDPOINT", "http://127.0.0.1:#{port}/v1")
    System.put_env("OPENAI_API_KEY", "sentinel-credential")
    config = CompletionConfig.new(recovery: [max_attempts: 3, base_delay: 0])

    assert [{:content, "sentinel-output"}, {:error, %CompletionError{} = error}] =
             OpenAI.complete_stream_events("gpt-4o", [Message.user("sentinel-input")], config)
             |> Enum.to_list()

    assert error.reason == :stream_interrupted
    assert error.progress.observed.content
    assert error.progress.delivered.content
    assert error.progress.raw_bytes == byte_size(frame)
    assert error.wire_attempt == 1
    assert length(error.history) == 1
    refute inspect(error) =~ "sentinel"
    [request] = GenServer.call(server, :requests)
    [_, body] = String.split(request, "\r\n\r\n", parts: 2)
    assert Jason.decode!(body)["messages"] == [%{"role" => "user", "content" => "sentinel-input"}]
  end

  for gateway <- [OpenAI, Ollama, OMLX], mode <- [:legacy, :events] do
    @gateway gateway
    @mode mode
    test "#{gateway} #{mode} recovers 503 with immutable full payload and exact lifecycle" do
      owner = self()

      server =
        server(@gateway, [http(503, "sentinel-error", "Retry-After: 1\r\n"), success(@gateway)])

      config =
        config(
          observer: &send(owner, {:event, &1}),
          sleeper: fn delay ->
            send(owner, {:delay, delay})
            :ok
          end
        )

      events = invoke(@gateway, @mode, config) |> Enum.to_list()
      assert hd(events) == {:content, "answer"}
      if @mode == :events, do: assert(match?({:completed, _}, List.last(events)))
      assert_receive {:delay, 1000}
      [first, second] = GenServer.call(server, :requests)
      assert first == second
      assert body(first)["messages"] == [%{"role" => "user", "content" => "sentinel-input"}]
      lifecycle = collect_events()

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

      assert_ids(lifecycle, 2)
      failed = Enum.at(lifecycle, 1).metadata
      assert failed.http_status == 503
      assert failed.retry_after == %{kind: :delay_seconds, value: 1}
      assert failed.provider_request_id == "fixture-73"
      assert failed.progress.headers_received
      refute inspect(lifecycle) =~ "sentinel"
    end

    test "#{gateway} #{mode} persistent failures preserve exact bounded identities and histories" do
      owner = self()
      server = server(@gateway, List.duplicate(http(504, "sentinel-error"), 3))

      assert [{:error, error}] =
               invoke(
                 @gateway,
                 @mode,
                 config(max_attempts: 3, observer: &send(owner, {:event, &1}))
               )
               |> Enum.to_list()

      assert error.wire_attempt == 3
      assert Enum.map(error.history, & &1.http_status) == [504, 504, 504]
      [first, second, third] = GenServer.call(server, :requests)
      assert first == second and second == third
      lifecycle = collect_events()

      assert Enum.map(lifecycle, & &1.type) == [
               :attempt_started,
               :attempt_failed,
               :admission_pending,
               :admission_allowed,
               :backoff_started,
               :retry_started,
               :attempt_started,
               :attempt_failed,
               :admission_pending,
               :admission_allowed,
               :backoff_started,
               :retry_started,
               :attempt_started,
               :attempt_failed,
               :exhausted
             ]

      assert_ids(lifecycle, 3)
      started = Enum.filter(lifecycle, &(&1.type == :attempt_started))

      assert Enum.map(started, & &1.metadata.attempt_id) ==
               Enum.map(error.history, & &1.attempt_id)

      assert Enum.all?(error.history, &(&1.logical_request_id == error.logical_request_id))
      refute Jason.encode!(error) =~ "sentinel"
    end

    for semantic <- [:content, :reasoning, :tools] do
      @semantic semantic
      test "#{gateway} #{mode} partial #{semantic} cannot replay or execute incomplete tools" do
        frame = partial(@gateway, @semantic)
        server = server(@gateway, [truncated(frame)])
        owner = self()

        events =
          invoke(@gateway, @mode, config(observer: &send(owner, {:event, &1}))) |> Enum.to_list()

        lifecycle = collect_events()
        assert Enum.map(lifecycle, & &1.type) == [:attempt_started, :attempt_failed, :exhausted]
        assert_ids(lifecycle, 1)
        assert {:error, error} = List.last(events)
        assert error.reason == :stream_interrupted
        assert error.http_status == 200
        assert error.provider_request_id == "fixture-73"
        assert error.progress.raw_bytes == byte_size(frame)
        assert error.progress.observed == semantic_progress(@semantic, true)
        delivered = @semantic == :content or (@semantic == :reasoning and @mode == :legacy)
        assert error.progress.delivered == semantic_progress(@semantic, delivered, 0)
        assert error.wire_attempt == 1
        assert length(error.history) == 1
        assert length(GenServer.call(server, :requests)) == 1
        refute Enum.any?(events, &match?({:completed, _}, &1))
        refute Enum.any?(events, &match?({:tool_calls, _}, &1))
        refute inspect(error) =~ "sentinel"
        assert CompletionError.cause(error) != nil
      end
    end

    test "#{gateway} #{mode} keepalive bytes recover without semantic progress" do
      keepalive = if @gateway == Ollama, do: "\n", else: ": keepalive\n\n"
      owner = self()
      server = server(@gateway, [truncated(keepalive), success(@gateway)])

      events =
        invoke(@gateway, @mode, config(observer: &send(owner, {:event, &1}))) |> Enum.to_list()

      assert hd(events) == {:content, "answer"}
      lifecycle = collect_events()
      assert Enum.map(lifecycle, & &1.type) == recovery_events()
      assert_ids(lifecycle, 2)
      failure = Enum.find(lifecycle, &(&1.type == :attempt_failed)).metadata
      assert failure.progress.raw_bytes == byte_size(keepalive)
      assert failure.progress.observed == semantic_progress(:content, false)
      [first, second] = GenServer.call(server, :requests)
      assert first == second
    end

    for phase <- [:active, :admission, :backoff] do
      @phase phase
      test "#{gateway} #{mode} cancellation during #{phase} sends no subsequent request" do
        owner = self()
        cancel = make_ref()
        response = if @phase == :active, do: :hold, else: http(503, "sentinel-error")
        server = server(@gateway, [response])

        opts =
          case @phase do
            :active ->
              []

            :admission ->
              [
                admission: fn context ->
                  send(owner, {:pending, context})
                  :pending
                end
              ]

            :backoff ->
              [
                sleeper: fn _ ->
                  send(owner, :sleeping)

                  receive do
                    :never -> :ok
                  end
                end
              ]
          end

        supervisor = start_supervised!(Task.Supervisor)

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            invoke(
              @gateway,
              @mode,
              config([cancel_ref: cancel, observer: &send(owner, {:event, &1})] ++ opts)
            )
            |> Enum.to_list()
          end)

        assert_receive {:wire_request, first}, 2000

        case @phase do
          :admission -> assert_receive {:pending, _}, 2000
          :backoff -> assert_receive :sleeping, 2000
          :active -> :ok
        end

        send(task.pid, {:cancel, cancel})
        assert [{:error, error}] = Task.await(task, 2000)
        assert error.category == :cancellation or error.resend_permission == :cancelled
        assert error.wire_attempt == 1
        assert GenServer.call(server, :requests) == [first]
        lifecycle = collect_events()
        assert Enum.map(lifecycle, & &1.type) == cancellation_events(@phase)
        assert_ids(lifecycle, 1)
      end
    end

    for decision <- [:allow, :reject] do
      @decision decision
      test "#{gateway} #{mode} pending admission #{@decision} is asynchronous and never counts as a wire attempt" do
        owner = self()
        server = server(@gateway, [http(503, "sentinel-error"), success(@gateway)])
        supervisor = start_supervised!(Task.Supervisor)

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            invoke(
              @gateway,
              @mode,
              config(
                observer: &send(owner, {:event, &1}),
                admission: fn context ->
                  send(owner, {:pending, context})
                  :pending
                end
              )
            )
            |> Enum.to_list()
          end)

        assert_receive {:wire_request, first}, 2000
        assert_receive {:pending, context}, 2000
        assert context.next_attempt == 2
        assert context.failure.wire_attempt == 1
        assert GenServer.call(server, :requests) == [first]
        send(context.reply_to, {:recovery_admission, context.ref, @decision})
        events = Task.await(task, 2000)
        lifecycle = collect_events()

        expected =
          if @decision == :allow,
            do: recovery_events(),
            else: [
              :attempt_started,
              :attempt_failed,
              :admission_pending,
              :admission_rejected,
              :exhausted
            ]

        assert Enum.map(lifecycle, & &1.type) == expected
        assert_ids(lifecycle, if(@decision == :allow, do: 2, else: 1))

        if @decision == :allow do
          assert hd(events) == {:content, "answer"}
          [^first, second] = GenServer.call(server, :requests)
          assert first == second
        else
          assert [{:error, error}] = events
          assert error.resend_permission == :rejected
          assert GenServer.call(server, :requests) == [first]
        end
      end
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    test "#{gateway} broker executes completed tool once then propagates follow-up interruption" do
      server =
        server(@gateway, [
          tool_response(@gateway),
          http(503, "sentinel-error"),
          truncated(partial(@gateway, :content))
        ])

      tool = %Mojentic.TestSupport.CountingTool{owner: self()}
      broker = Broker.new("gpt-4o", @gateway)
      owner = self()
      config = %{config(observer: &send(owner, {:event, &1})) | max_tool_iterations: 1}

      assert ["sentinel-output", {:error, error}] =
               Broker.generate_stream(broker, [Message.user("sentinel-input")], [tool], config)
               |> Enum.to_list()

      assert error.reason == :stream_interrupted
      lifecycle = collect_events()

      assert Enum.map(lifecycle, & &1.type) == [
               :attempt_started,
               :attempt_succeeded,
               :attempt_started,
               :attempt_failed,
               :admission_pending,
               :admission_allowed,
               :backoff_started,
               :retry_started,
               :attempt_started,
               :attempt_failed,
               :exhausted
             ]

      [tool_attempt, followup, retry] = Enum.filter(lifecycle, &(&1.type == :attempt_started))
      assert Enum.map([tool_attempt, followup, retry], & &1.metadata.wire_attempt) == [1, 1, 2]
      assert tool_attempt.metadata.logical_request_id != followup.metadata.logical_request_id
      assert followup.metadata.logical_request_id == retry.metadata.logical_request_id
      assert followup.metadata.attempt_id != retry.metadata.attempt_id

      assert Enum.map(error.history, & &1.attempt_id) == [
               followup.metadata.attempt_id,
               retry.metadata.attempt_id
             ]

      assert Enum.map(error.history, & &1.http_status) == [503, 200]
      assert_receive {:tool_executed, %{"value" => "sentinel-tool"}}
      refute_receive {:tool_executed, _}
      [first, second, third] = GenServer.call(server, :requests)
      assert second == third
      assert length(body(first)["messages"]) == 1
      messages = body(second)["messages"]

      assert Enum.any?(
               messages,
               &(&1["role"] == "tool" and &1["content"] == Jason.encode!("tool-result-secret"))
             )

      assert Enum.count(messages, &(&1["role"] == "tool")) == 1
    end

    test "#{gateway} session refuses to finalize partial output after a completed tool" do
      server = server(@gateway, [tool_response(@gateway), truncated(partial(@gateway, :content))])
      tool = %Mojentic.TestSupport.CountingTool{owner: self()}
      session = ChatSession.new(Broker.new("gpt-4o", @gateway), tools: [tool])
      original = ChatSession.messages(session)

      assert {:ok, stream, handle} =
               ChatSession.send_stream(session, "sentinel-input", recovery: config().recovery)

      assert ["sentinel-output", {:error, error}] = Enum.to_list(stream)
      assert ChatSession.finalize_stream(handle) == {:error, error}
      assert ChatSession.messages(session) == original
      assert_receive {:tool_executed, %{"value" => "sentinel-tool"}}
      refute_receive {:tool_executed, _}
      assert length(GenServer.call(server, :requests)) == 2
    end

    test "#{gateway} broker recovery does not replenish streaming tool depth" do
      server =
        server(@gateway, [
          tool_response(@gateway),
          http(503, "sentinel-error"),
          tool_response(@gateway)
        ])

      tool = %Mojentic.TestSupport.CountingTool{owner: self()}
      broker = Broker.new("gpt-4o", @gateway)

      assert [{:error, :max_tool_iterations_exceeded}] =
               Broker.generate_stream(broker, [Message.user("sentinel-input")], [tool], %{
                 config()
                 | max_tool_iterations: 1
               })
               |> Enum.to_list()

      assert_receive {:tool_executed, %{"value" => "sentinel-tool"}}
      refute_receive {:tool_executed, _}
      [_, second, third] = GenServer.call(server, :requests)
      assert second == third
    end

    for mode <- [:legacy, :events] do
      @mode mode
      test "#{gateway} #{mode} consumer halt closes owned HTTP and recovery workers" do
        # One data frame followed by a pending socket keeps ownership observable.
        frame = partial(@gateway, :content)

        server =
          server(@gateway, [
            {:stream_hold,
             http(200, frame)
             |> String.replace("Content-Length: #{byte_size(frame)}", "Content-Length: 999999")}
          ])

        assert [{:content, "sentinel-output"}] = invoke(@gateway, @mode, config()) |> Enum.take(1)
        assert GenServer.call(server, :closed_sockets) == [:closed]
        assert length(GenServer.call(server, :requests)) == 1
      end
    end
  end

  defp tool_response(Ollama) do
    http(
      200,
      Jason.encode!(%{
        message: %{
          tool_calls: [%{function: %{name: "count", arguments: %{value: "sentinel-tool"}}}]
        },
        done: true,
        done_reason: "stop"
      }) <> "\n"
    )
  end

  defp tool_response(_) do
    http(
      200,
      sse(%{
        choices: [
          %{
            delta: %{
              tool_calls: [
                %{
                  index: 0,
                  id: "call-17",
                  function: %{name: "count", arguments: ~s({"value":"sentinel-tool"})}
                }
              ]
            },
            finish_reason: "tool_calls"
          }
        ]
      }) <> "data: [DONE]\n\n"
    )
  end

  for gateway <- [OpenAI, Ollama, OMLX], mode <- [:legacy, :events] do
    @gateway gateway
    @mode mode
    test "#{gateway} #{mode} Retry-After ceiling refuses resend and preserves original HTTP failure" do
      server = server(@gateway, [http(429, "sentinel-error", "Retry-After: 11\r\n")])

      assert [{:error, error}] =
               invoke(@gateway, @mode, config(delay_ceiling: 100)) |> Enum.to_list()

      assert error.http_status == 429
      assert error.retry_after == {:delay_seconds, 11}
      assert error.resend_permission == :retry_after_ceiling
      assert error.wire_attempt == 1
      assert length(GenServer.call(server, :requests)) == 1
    end

    test "#{gateway} #{mode} cancellation after delivery preserves exact semantic and raw progress" do
      frame = partial(@gateway, :content)

      response =
        String.replace(
          http(200, frame),
          "Content-Length: #{byte_size(frame)}",
          "Content-Length: 999999"
        )

      server = server(@gateway, [{:stream_hold, response}])
      owner = self()
      cancel = make_ref()
      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          invoke(@gateway, @mode, config(cancel_ref: cancel))
          |> Stream.each(fn item -> send(owner, {:delivered, item}) end)
          |> Enum.to_list()
        end)

      assert_receive {:delivered, {:content, "sentinel-output"}}, 2000
      send(task.pid, {:cancel, cancel})
      assert [{:content, "sentinel-output"}, {:error, error}] = Task.await(task, 2000)
      assert error.category == :cancellation
      assert error.reason == :stream_interrupted
      assert error.progress.observed == semantic_progress(:content, true)
      assert error.progress.delivered == semantic_progress(:content, true)
      assert error.progress.raw_bytes == byte_size(frame)
      assert GenServer.call(server, :closed_sockets) == [:closed]
      assert length(GenServer.call(server, :requests)) == 1
    end

    test "#{gateway} #{mode} broker default tracing and lifecycle serialization exclude sentinel payloads" do
      owner = self()
      tracer = start_supervised!({Mojentic.Tracer.TracerSystem, []})
      _server = server(@gateway, [truncated(partial(@gateway, :content))])
      broker = Broker.new("gpt-4o", @gateway, tracer: tracer)
      config = config(observer: &send(owner, {:event, &1}))

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          stream =
            if @mode == :events,
              do: Broker.generate_stream_events(broker, [Message.user("sentinel-input")], config),
              else: Broker.generate_stream(broker, [Message.user("sentinel-input")], nil, config)

          assert {:error, error} = stream |> Enum.to_list() |> List.last()
          refute inspect(error) =~ "sentinel"
          refute Jason.encode!(error) =~ "sentinel"
        end)

      assert Mojentic.Tracer.TracerSystem.get_events(tracer) == []
      refute logs =~ "sentinel"
      refute inspect(collect_events()) =~ "sentinel"
    end

    for status <- [400, 401] do
      @status status
      test "#{gateway} #{mode} HTTP #{status} cannot become retryable through caller selection" do
        server = server(@gateway, [http(@status, "sentinel-error")])

        assert [{:error, error}] =
                 invoke(@gateway, @mode, config(retryable_statuses: [@status])) |> Enum.to_list()

        assert error.http_status == @status
        assert error.wire_attempt == 1
        assert length(GenServer.call(server, :requests)) == 1
      end
    end
  end

  for gateway <- [Ollama, OMLX], mode <- [:legacy, :events] do
    @gateway gateway
    @mode mode
    test "#{gateway} #{mode} ambiguous local failure requires admission by default" do
      server = server(@gateway, [http(503, "sentinel-error")])
      config = CompletionConfig.new(recovery: [max_attempts: 2, base_delay: 0])
      assert [{:error, error}] = invoke(@gateway, @mode, config) |> Enum.to_list()
      assert error.resend_permission == :admission_required
      assert error.acceptance == :unknown
      assert length(GenServer.call(server, :requests)) == 1
    end
  end

  for gateway <- [OpenAI, OMLX] do
    @gateway gateway
    test "#{gateway} completed tool deltas followed by wire failure expose progress without execution" do
      response = tool_response(@gateway)
      [_, frames] = String.split(response, "\r\n\r\n", parts: 2)
      frame = String.replace(frames, "data: [DONE]\n\n", "")
      server = server(@gateway, [truncated(frame)])
      tool = %Mojentic.TestSupport.CountingTool{owner: self()}
      broker = Broker.new("gpt-4o", @gateway)

      assert [{:error, error}] =
               Broker.generate_stream(broker, [Message.user("sentinel-input")], [tool], config())
               |> Enum.to_list()

      assert error.reason == :stream_interrupted

      assert error.progress.observed == %{
               content: false,
               reasoning: false,
               tool_fragments: 1,
               completed_tool_calls: 1
             }

      assert error.progress.delivered == %{
               content: false,
               reasoning: false,
               tool_fragments: 0,
               completed_tool_calls: 1
             }

      assert error.progress.raw_bytes == byte_size(frame)
      refute_receive {:tool_executed, _}
      assert length(GenServer.call(server, :requests)) == 1
    end
  end

  for mode <- [:legacy, :events] do
    @mode mode
    test "Ollama #{mode} final frame without newline retains exact raw byte count" do
      response = success(Ollama)
      [_, frame] = String.split(response, "\r\n\r\n", parts: 2)
      frame = String.trim_trailing(frame, "\n")
      server(Ollama, [http(200, frame)])
      assert hd(invoke(Ollama, @mode, config()) |> Enum.to_list()) == {:content, "answer"}
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], mode <- [:legacy, :events] do
    @gateway gateway
    @mode mode
    test "#{gateway} #{mode} consuming process death closes its live socket" do
      frame = partial(@gateway, :content)

      response =
        String.replace(
          http(200, frame),
          "Content-Length: #{byte_size(frame)}",
          "Content-Length: 999999"
        )

      server = server(@gateway, [{:stream_hold, response}])
      owner = self()
      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          invoke(@gateway, @mode, config())
          |> Stream.each(fn item -> send(owner, {:delivered, item}) end)
          |> Enum.to_list()
        end)

      assert_receive {:delivered, {:content, "sentinel-output"}}, 2000
      monitor = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}
      assert GenServer.call(server, :closed_sockets) == [:closed]
      assert length(GenServer.call(server, :requests)) == 1
    end

    test "#{gateway} #{mode} recovery deadline is not a total active generation timeout" do
      clock = start_supervised!({Agent, fn -> 0 end})
      server = server(@gateway, [:hold])
      supervisor = start_supervised!(Task.Supervisor)
      config = config(deadline: 100, clock: fn -> Agent.get(clock, & &1) end)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          invoke(@gateway, @mode, config) |> Enum.to_list()
        end)

      assert_receive {:wire_request, request}, 2000
      Agent.update(clock, fn _ -> 1000 end)
      assert :ok = GenServer.call(server, {:release, success(@gateway)})
      assert hd(Task.await(task, 2000)) == {:content, "answer"}
      assert GenServer.call(server, :requests) == [request]
    end
  end

  defp config(opts \\ []) do
    recovery =
      Keyword.merge(
        [max_attempts: 2, base_delay: 0, admission: fn _ -> :allow end, sleeper: fn _ -> :ok end],
        opts
      )

    CompletionConfig.new(recovery: recovery)
  end

  defp invoke(gateway, :events, config),
    do: gateway.complete_stream_events("gpt-4o", [Message.user("sentinel-input")], config)

  defp invoke(gateway, :legacy, config),
    do: gateway.complete_stream("gpt-4o", [Message.user("sentinel-input")], nil, config)

  defp server(gateway, responses) do
    server = start_supervised!({ScriptedCompletionServer, {self(), responses}})
    assert_receive {:server_port, port}
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end

    System.put_env("OPENAI_API_KEY", "sentinel-credential")
    System.put_env("OMLX_API_KEY", "sentinel-credential")
    server
  end

  defp body(request),
    do: request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()

  defp http(status, body, headers \\ ""),
    do:
      "HTTP/1.1 #{status} Result\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\nX-Request-ID: fixture-73\r\n#{headers}\r\n#{body}"

  defp truncated(body),
    do:
      String.replace(
        http(200, body),
        "Content-Length: #{byte_size(body)}",
        "Content-Length: #{byte_size(body) + 100}"
      )

  defp sse(object), do: "data: #{Jason.encode!(object)}\n\n"

  defp success(Ollama),
    do:
      http(
        200,
        Jason.encode!(%{message: %{content: "answer"}, done: true, done_reason: "stop"}) <> "\n"
      )

  defp success(_),
    do:
      http(
        200,
        sse(%{choices: [%{delta: %{content: "answer"}, finish_reason: "stop"}]}) <>
          "data: [DONE]\n\n"
      )

  defp partial(gateway, semantic) do
    delta =
      case semantic do
        :content ->
          %{content: "sentinel-output"}

        :reasoning ->
          %{reasoning_content: "sentinel-reasoning", thinking: "sentinel-reasoning"}

        :tools ->
          %{
            tool_calls: [
              %{
                index: 0,
                id: "call-1",
                function: %{name: "count", arguments: "sentinel-fragment"}
              }
            ]
          }
      end

    if gateway == Ollama,
      do: Jason.encode!(%{message: delta, done: false}) <> "\n",
      else: sse(%{choices: [%{delta: delta}]})
  end

  defp semantic_progress(kind, present, fragments \\ 1),
    do: %{
      content: kind == :content and present,
      reasoning: kind == :reasoning and present,
      tool_fragments: if(kind == :tools and present, do: fragments, else: 0),
      completed_tool_calls: 0
    }

  defp collect_events do
    receive do
      {:event, event} -> [event | collect_events()]
    after
      0 -> []
    end
  end

  defp recovery_events,
    do: [
      :attempt_started,
      :attempt_failed,
      :admission_pending,
      :admission_allowed,
      :backoff_started,
      :retry_started,
      :attempt_started,
      :attempt_succeeded
    ]

  defp cancellation_events(:active), do: [:attempt_started, :attempt_failed, :cancelled]

  defp cancellation_events(:admission),
    do: [:attempt_started, :attempt_failed, :admission_pending, :admission_rejected, :cancelled]

  defp cancellation_events(:backoff),
    do: [
      :attempt_started,
      :attempt_failed,
      :admission_pending,
      :admission_allowed,
      :backoff_started,
      :cancelled
    ]

  defp assert_ids(events, attempts) do
    starts = Enum.filter(events, &(&1.type == :attempt_started))
    assert Enum.map(starts, & &1.metadata.wire_attempt) == Enum.to_list(1..attempts)
    assert length(Enum.uniq(Enum.map(starts, & &1.metadata.attempt_id))) == attempts
    assert length(Enum.uniq(Enum.map(starts, & &1.metadata.logical_request_id))) == 1

    for event <- events, event.type not in [:retry_started] do
      assert Enum.any?(starts, &(&1.metadata.attempt_id == event.metadata.attempt_id))
    end
  end
end
