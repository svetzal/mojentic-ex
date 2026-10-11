defmodule Mojentic.LLM.ImmutableRequestWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, Message, ToolCall}
  alias Mojentic.LLM.Gateways.{Ollama, OMLX, OpenAI}
  alias Mojentic.TestSupport.{CountingTool, ScriptedCompletionServer, StubTokenizer}

  @original "original-image-π"
  @changed "changed-image-δ"
  @keys ["OPENAI_API_ENDPOINT", "OPENAI_API_KEY", "OLLAMA_HOST", "OMLX_HOST", "OMLX_API_KEY"]

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)
    saved = Map.new(@keys, &{&1, System.get_env(&1)})
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
    path = Path.join(System.tmp_dir!(), "immutable-#{System.unique_integer([:positive])}.png")
    File.write!(path, @original)

    on_exit(fn ->
      File.rm!(path)
      Application.put_env(:mojentic, :http_client, client)

      for {key, value} <- saved do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    %{path: path}
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    @tag :immutable_proof
    test "#{gateway} broker admitted follow-up freezes complete history and mutable image without tool replay",
         %{path: path} do
      owner = self()

      server =
        server(@gateway, [
          tool_response(@gateway),
          http(503, "busy"),
          success(@gateway, :complete)
        ])

      config = config(path, owner)

      assert {:ok, "answer"} =
               Broker.generate(
                 Broker.new("gpt-4o", @gateway),
                 history(path),
                 [%CountingTool{owner: owner}],
                 config
               )

      assert_receive {:tool_executed, %{"value" => "next-π"}}
      refute_receive {:tool_executed, _}
      [initial, first, second] = GenServer.call(server, :requests) |> Enum.map(&encoded/1)
      expected = expected(@gateway, :complete, "gpt-4o")
      assert Jason.decode!(initial) == expected

      calls =
        if @gateway == Ollama do
          [
            %{
              "type" => "function",
              "function" => %{"name" => "count", "arguments" => %{"value" => "next-π"}}
            }
          ]
        else
          [
            %{
              "id" => "next-id",
              "type" => "function",
              "function" => %{"name" => "count", "arguments" => "{\"value\":\"next-π\"}"}
            }
          ]
        end

      result =
        if @gateway == Ollama do
          %{"role" => "tool", "content" => "\"tool-result-secret\"", "tool_calls" => calls}
        else
          %{"role" => "tool", "content" => "\"tool-result-secret\"", "tool_call_id" => "next-id"}
        end

      followup =
        expected["messages"] ++
          [%{"role" => "assistant", "content" => "", "tool_calls" => calls}, result]

      assert Jason.decode!(first) == %{expected | "messages" => followup}
      assert first == second
      assert File.read!(path) == @changed
      assert_evidence([initial, first, second], [1, 1, 2])
      stop_supervised!(ScriptedCompletionServer)
      drain(:wire_request)
      File.write!(path, @original)
      baseline = server(@gateway, [tool_response(@gateway), success(@gateway, :complete)])

      assert {:ok, "answer"} =
               Broker.generate(
                 Broker.new("gpt-4o", @gateway),
                 history(path),
                 [%CountingTool{owner: owner}],
                 config(path, owner, :disabled)
               )

      assert GenServer.call(baseline, :requests) |> Enum.map(&encoded/1) == [initial, first]
      assert_receive {:tool_executed, %{"value" => "next-π"}}
      refute_receive {:tool_executed, _}
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :object, :legacy, :events],
      boundary <- [:gateway, :broker] do
    @gateway gateway
    @operation operation
    @boundary boundary
    test "#{gateway} #{boundary} #{operation} independently specified payload equals disabled wire and admitted retry",
         %{path: path} do
      owner = self()
      baseline = server(@gateway, List.duplicate(success(@gateway, @operation), 2))

      invoke(
        @gateway,
        @operation,
        history(path),
        config(path, owner, :disabled),
        "gpt-4o",
        @boundary
      )

      disabled = GenServer.call(baseline, :requests) |> Enum.map(&encoded/1)
      assert length(disabled) == if(@gateway == Ollama and @operation == :legacy, do: 2, else: 1)
      expected = expected(@gateway, @operation, "gpt-4o")
      assert Enum.all?(disabled, &(Jason.decode!(&1) == expected))
      stop_supervised!(ScriptedCompletionServer)
      drain(:wire_request)

      retry = server(@gateway, [http(503, "busy"), success(@gateway, @operation)])
      invoke(@gateway, @operation, history(path), config(path, owner), "gpt-4o", @boundary)
      [first, second] = GenServer.call(retry, :requests) |> Enum.map(&encoded/1)
      assert Jason.decode!(first) == expected
      assert first == second
      assert first == hd(disabled)
      assert File.read!(path) == @changed
      assert_evidence([first, second], [1, 2])
    end
  end

  for operation <- [:complete, :object, :legacy, :events], effort <- [:low, :medium, :high] do
    @operation operation
    @effort effort
    test "OpenAI o3 #{operation} preserves supported #{@effort} reasoning controls and model adaptation",
         %{path: path} do
      owner = self()
      baseline_config = %{config(path, owner, :disabled) | reasoning_effort: @effort}
      baseline = server(OpenAI, List.duplicate(success(OpenAI, @operation), 2))
      invoke(OpenAI, @operation, history(path), baseline_config, "o3")
      [disabled] = GenServer.call(baseline, :requests) |> Enum.map(&encoded/1)
      stop_supervised!(ScriptedCompletionServer)
      drain(:wire_request)
      retry = server(OpenAI, [http(503, "busy"), success(OpenAI, @operation)])

      invoke(
        OpenAI,
        @operation,
        history(path),
        %{config(path, owner) | reasoning_effort: @effort},
        "o3"
      )

      [first, second] = GenServer.call(retry, :requests) |> Enum.map(&encoded/1)

      expected =
        expected(OpenAI, @operation, "o3")
        |> Map.put("temperature", 1.0)
        |> Map.delete("max_tokens")
        |> Map.put("max_completion_tokens", 73)
        |> Map.put("reasoning_effort", Atom.to_string(@effort))

      assert Jason.decode!(first) == expected
      assert first == second and first == disabled
      assert_evidence([first, second], [1, 2])
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :legacy] do
    @gateway gateway
    @operation operation
    test "#{gateway} session #{operation} retries complete prior conversation with default controls",
         %{path: path} do
      owner = self()

      baseline =
        server(@gateway, [
          success(@gateway, :complete) | List.duplicate(success(@gateway, @operation), 2)
        ])

      session_turn(@gateway, @operation, nil)
      disabled = GenServer.call(baseline, :requests) |> Enum.map(&encoded/1)
      stop_supervised!(ScriptedCompletionServer)
      drain(:wire_request)

      retry =
        server(@gateway, [
          success(@gateway, :complete),
          http(503, "busy"),
          success(@gateway, @operation)
        ])

      session_turn(@gateway, @operation, config(path, owner).recovery)
      [warm, first, second] = GenServer.call(retry, :requests) |> Enum.map(&encoded/1)
      assert warm == hd(disabled)
      assert first == second and first == Enum.at(disabled, 1)

      messages = [
        %{"role" => "system", "content" => "session-system"},
        %{"role" => "user", "content" => "warm"},
        %{"role" => "assistant", "content" => "answer"},
        %{"role" => "user", "content" => "follow"}
      ]

      expected = %{
        "model" => "gpt-4o",
        "messages" => messages,
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "count",
              "description" => "count",
              "parameters" => %{"type" => "object"}
            }
          }
        ]
      }

      expected =
        if @gateway == Ollama do
          Map.merge(expected, %{
            "options" => %{"temperature" => 1.0, "num_ctx" => 32_768, "num_predict" => 16_384},
            "stream" => @operation == :legacy
          })
        else
          Map.merge(expected, %{"temperature" => 1.0, "max_tokens" => 16_384})
        end

      expected =
        if @gateway != Ollama and @operation == :legacy,
          do: Map.put(expected, "stream", true),
          else: expected

      assert Jason.decode!(first) == expected
      assert_evidence([first, second], [1, 2])
    end
  end

  defp session_turn(gateway, operation, recovery) do
    session =
      ChatSession.new(Broker.new("gpt-4o", gateway),
        system_prompt: "session-system",
        tokenizer: StubTokenizer.new!(),
        tools: [%CountingTool{owner: self()}]
      )

    assert {:ok, "answer", session} = ChatSession.send(session, "warm")

    session =
      case operation do
        :complete ->
          assert {:ok, "answer", updated} =
                   ChatSession.send(session, "follow", recovery: recovery)

          updated

        :legacy ->
          assert {:ok, stream, handle} =
                   ChatSession.send_stream(session, "follow", recovery: recovery)

          result = Enum.to_list(stream)
          assert "answer" in result
          refute Enum.any?(result, &match?({:error, _}, &1))
          ChatSession.finalize_stream(handle)
      end

    assert Enum.map(ChatSession.messages(session), & &1.message) == [
             Message.system("session-system"),
             Message.user("warm"),
             Message.assistant("answer"),
             Message.user("follow"),
             Message.assistant("answer")
           ]
  end

  defp invoke(gateway, operation, messages, config, model, boundary \\ :gateway) do
    tools = [%CountingTool{owner: self()}]

    case operation do
      :complete ->
        if boundary == :broker do
          assert {:ok, "answer"} =
                   Broker.generate(Broker.new(model, gateway), messages, tools, config)
        else
          assert {:ok, %{content: "answer"}} = gateway.complete(model, messages, tools, config)
        end

      :object ->
        if boundary == :broker do
          assert {:ok, %{"answer" => "answer"}} =
                   Broker.generate_object(Broker.new(model, gateway), messages, schema(), config)
        else
          assert {:ok, %{object: %{"answer" => "answer"}}} =
                   gateway.complete_object(model, messages, schema(), config)
        end

      :legacy ->
        stream =
          if boundary == :broker,
            do: Broker.generate_stream(Broker.new(model, gateway), messages, tools, config),
            else: gateway.complete_stream(model, messages, tools, config)

        result = Enum.to_list(stream)

        assert Enum.any?(
                 result,
                 &(&1 == if(boundary == :broker, do: "answer", else: {:content, "answer"}))
               )

        refute Enum.any?(result, &match?({:error, _}, &1))

      :events ->
        stream =
          if boundary == :broker,
            do: Broker.generate_stream_events(Broker.new(model, gateway), messages, config),
            else: gateway.complete_stream_events(model, messages, config)

        result = Enum.to_list(stream)
        assert Enum.any?(result, &(&1 == {:content, "answer"}))
        assert match?({:completed, _}, List.last(result))
    end
  end

  defp history(path) do
    call = %ToolCall{id: "history-id", name: "count", arguments: %{"value" => "history-π"}}

    [
      Message.system("system-π"),
      %Message{role: :user, content: "user-π", image_paths: [path]},
      Message.assistant("ordinary assistant text"),
      %Message{role: :assistant, content: "calling", tool_calls: [call]},
      %Message{role: :tool, content: "history-result-δ", tool_calls: [call]}
    ]
  end

  defp config(path, owner, recovery \\ :enabled) do
    policy =
      if recovery == :enabled do
        [
          max_attempts: 2,
          base_delay: 0,
          admission: fn context ->
            File.write!(path, @changed)
            send(owner, {:admitted, context})
            :allow
          end,
          sleeper: fn _ -> :ok end,
          observer: fn event ->
            send(owner, {:timeline, {:lifecycle, event}})
            send(owner, {:lifecycle, event})
          end,
          trace_observer: fn event ->
            send(owner, {:timeline, {:trace, event}})
            send(owner, {:trace, event})
            :ok
          end
        ]
      end

    CompletionConfig.new(
      temperature: 0.6,
      num_ctx: 8192,
      max_tokens: 73,
      num_predict: 61,
      top_p: 0.8,
      top_k: 17,
      reasoning_effort: :high,
      response_format: %{type: :json_object, schema: schema()},
      recovery: policy
    )
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "additionalProperties" => false
    }
  end

  defp expected(gateway, operation, model) do
    calls = [
      %{
        "type" => "function",
        "function" => %{"name" => "count", "arguments" => %{"value" => "history-π"}}
      }
    ]

    calls =
      if gateway == Ollama,
        do: calls,
        else: [
          %{
            "id" => "history-id",
            "type" => "function",
            "function" => %{"name" => "count", "arguments" => "{\"value\":\"history-π\"}"}
          }
        ]

    user =
      if gateway == Ollama do
        %{"role" => "user", "content" => "user-π", "images" => [Base.encode64(@original)]}
      else
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "user-π"},
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/png;base64," <> Base.encode64(@original)}
            }
          ]
        }
      end

    tool =
      if gateway == Ollama,
        do: %{"role" => "tool", "content" => "history-result-δ", "tool_calls" => calls},
        else: %{"role" => "tool", "content" => "history-result-δ", "tool_call_id" => "history-id"}

    messages = [
      %{"role" => "system", "content" => "system-π"},
      user,
      %{"role" => "assistant", "content" => "ordinary assistant text"},
      %{"role" => "assistant", "content" => "calling", "tool_calls" => calls},
      tool
    ]

    body = %{"model" => model, "messages" => messages}

    body =
      case gateway do
        Ollama ->
          Map.merge(body, %{
            "options" => %{
              "temperature" => 0.6,
              "num_ctx" => 8192,
              "num_predict" => 61,
              "top_p" => 0.8,
              "top_k" => 17
            },
            "format" => schema(),
            "stream" => operation in [:legacy, :events]
          })

        OMLX ->
          Map.merge(body, %{
            "temperature" => 0.6,
            "max_tokens" => 73,
            "top_p" => 0.8,
            "top_k" => 17,
            "reasoning_effort" => "high",
            "response_format" => %{
              "type" => "json_schema",
              "json_schema" => %{"name" => "response", "schema" => schema()}
            }
          })

        OpenAI ->
          Map.merge(body, %{
            "temperature" => 0.6,
            "max_tokens" => 73,
            "top_p" => 0.8,
            "response_format" => %{
              "type" => "json_schema",
              "json_schema" => %{"name" => "response", "schema" => schema()}
            }
          })
      end

    body =
      if gateway == Ollama and operation != :object, do: Map.put(body, "think", true), else: body

    body =
      if gateway != Ollama and operation in [:legacy, :events],
        do: Map.put(body, "stream", true),
        else: body

    body =
      if gateway != Ollama and operation == :events,
        do: Map.put(body, "stream_options", %{"include_usage" => true}),
        else: body

    if operation in [:complete, :legacy],
      do:
        Map.put(body, "tools", [
          %{
            "type" => "function",
            "function" => %{
              "name" => "count",
              "description" => "count",
              "parameters" => %{"type" => "object"}
            }
          }
        ]),
      else: body
  end

  defp server(gateway, responses) do
    server = start_supervised!({ScriptedCompletionServer, {self(), responses}})
    assert_receive {:server_port, port}
    endpoint = "http://127.0.0.1:#{port}"

    case gateway do
      OpenAI ->
        System.put_env("OPENAI_API_ENDPOINT", endpoint <> "/v1")
        System.put_env("OPENAI_API_KEY", "fixture")

      Ollama ->
        System.put_env("OLLAMA_HOST", endpoint)

      OMLX ->
        System.put_env("OMLX_HOST", endpoint)
        System.put_env("OMLX_API_KEY", "fixture")
    end

    server
  end

  defp http(status, body),
    do:
      "HTTP/1.1 #{status} fixture\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

  defp encoded(wire), do: wire |> String.split("\r\n\r\n", parts: 2) |> List.last()

  defp success(gateway, operation) when operation in [:legacy, :events] do
    body =
      if gateway == Ollama do
        Jason.encode!(%{message: %{content: "answer"}, done: false}) <>
          "\n" <>
          Jason.encode!(%{message: %{content: ""}, done: true, done_reason: "stop"}) <> "\n"
      else
        "data: " <>
          Jason.encode!(%{
            choices: [%{index: 0, delta: %{content: "answer"}, finish_reason: nil}]
          }) <>
          "\n\n" <>
          "data: " <>
          Jason.encode!(%{choices: [%{index: 0, delta: %{}, finish_reason: "stop"}]}) <>
          "\n\ndata: [DONE]\n\n"
      end

    http(200, body)
  end

  defp success(gateway, operation) do
    content = if operation == :object, do: "{\"answer\":\"answer\"}", else: "answer"

    body =
      if gateway == Ollama,
        do: %{"message" => %{"content" => content}, "done" => true, "done_reason" => "stop"},
        else: %{"choices" => [%{"message" => %{"content" => content}, "finish_reason" => "stop"}]}

    http(200, Jason.encode!(body))
  end

  defp tool_response(gateway) do
    call = %{
      "id" => "next-id",
      "type" => "function",
      "function" => %{"name" => "count", "arguments" => "{\"value\":\"next-π\"}"}
    }

    call =
      if gateway == Ollama,
        do: %{"function" => %{"name" => "count", "arguments" => %{"value" => "next-π"}}},
        else: call

    message = %{"content" => "", "tool_calls" => [call]}

    body =
      if gateway == Ollama,
        do: %{"message" => message, "done" => true, "done_reason" => "stop"},
        else: %{"choices" => [%{"message" => message, "finish_reason" => "tool_calls"}]}

    http(200, Jason.encode!(body))
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, event} -> drain(tag, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_evidence(bodies, attempts) do
    timeline = drain(:timeline)
    traces = drain(:trace)
    lifecycle = drain(:lifecycle)
    requests = Enum.filter(traces, &(&1.type == :request))
    assert Enum.map(requests, & &1.body) == bodies
    assert Enum.map(requests, & &1.ids.wire_attempt) == attempts
    assert_attempt_ids(requests, lifecycle)
    [first, second] = Enum.take(requests, -2)
    assert first.ids.logical_request_id == second.ids.logical_request_id

    assert Enum.map(Enum.take(lifecycle, -8), & &1.type) == [
             :attempt_started,
             :attempt_failed,
             :admission_pending,
             :admission_allowed,
             :backoff_started,
             :retry_started,
             :attempt_started,
             :attempt_succeeded
           ]

    for request <- requests do
      assert_trace_attempt(request, first, traces, timeline)
    end

    if length(requests) == 3 do
      assert hd(requests).ids.logical_request_id != first.ids.logical_request_id

      assert Enum.map(Enum.take(lifecycle, 2), & &1.type) == [
               :attempt_started,
               :attempt_succeeded
             ]
    end

    assert_receive {:admitted, context}
    assert context.failure.attempt_id == first.ids.attempt_id
  end

  defp assert_attempt_ids(requests, lifecycle) do
    started = Enum.filter(lifecycle, &(&1.type == :attempt_started))

    assert Enum.map(
             started,
             &Map.take(&1.metadata, [:logical_request_id, :attempt_id, :wire_attempt])
           ) == Enum.map(requests, & &1.ids)

    assert length(Enum.uniq(Enum.map(requests, & &1.ids.attempt_id))) == length(requests)
  end

  defp assert_trace_attempt(request, first, traces, timeline) do
    id = request.ids.attempt_id

    order =
      Enum.flat_map(timeline, fn
        {:trace, %{ids: %{attempt_id: ^id}, type: type}} -> [type]
        {:lifecycle, %{metadata: %{attempt_id: ^id}, type: type}} -> [type]
        _ -> []
      end)

    assert Enum.take(order, 2) == [:attempt_started, :request]
    ending = if request == first, do: :attempt_failed, else: :attempt_succeeded

    assert Enum.find_index(order, &(&1 == :response_end)) <
             Enum.find_index(order, &(&1 == ending))

    events = Enum.filter(traces, &(&1.ids == request.ids))
    assert hd(events).type == :request
    assert List.last(events).type == :response_end
    assert Enum.count(events, &(&1.type == :request)) == 1
    assert Enum.count(events, &(&1.type == :response_end)) == 1
  end
end
