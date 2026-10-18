defmodule Mojentic.LLM.ImmutableRequestWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, Message, ToolCall}
  alias Mojentic.LLM.Gateways.{Ollama, OMLX, OpenAI}
  alias Mojentic.TestSupport.{CountingTool, ScriptedTransport, StubTokenizer}

  @external_resource "test/contracts/request_fidelity_v1.json"
  @contract Jason.decode!(File.read!(@external_resource))

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

  for gateway <- [OpenAI, Ollama, OMLX],
      boundary <- [:broker, :session],
      row <- @contract["cases"] do
    @gateway gateway
    @boundary boundary
    @row row
    @tag :legacy_continuation_fidelity
    test "fidelity-v1 #{gateway} #{boundary} legacy tool continuation #{row["name"]} exact bodies and admitted replay" do
      owner = self()

      server =
        server(@gateway, [
          streaming_tool_response(@gateway),
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
          success(@gateway, :legacy)
        ])

      recovery = [
        max_attempts: 2,
        base_delay: 0,
        admission: fn context ->
          send(owner, {:continuation_admitted, context})
          :allow
        end,
        sleeper: fn _ -> :ok end
      ]

      opts =
        for field <- [:temperature, :num_ctx, :max_tokens, :top_p, :top_k],
            Map.has_key?(@row["config"], Atom.to_string(field)),
            do: {field, @row["config"][Atom.to_string(field)]}

      opts = Keyword.put(opts, :recovery, recovery)
      broker = Broker.new("gpt-4o", @gateway)
      tools = [%CountingTool{owner: owner}]

      output =
        case @boundary do
          :broker ->
            Broker.generate_stream(
              broker,
              [Message.system("system"), Message.user("question")],
              tools,
              CompletionConfig.new(opts)
            )
            |> Enum.to_list()

          :session ->
            temperature = if @row["name"] in ["zero-temperature", "all", "explicit-nil"], do: 0.6

            session =
              ChatSession.new(broker,
                system_prompt: "system",
                tools: tools,
                tokenizer: StubTokenizer.new!(),
                max_context: 1000,
                temperature: temperature
              )

            assert {:ok, stream, handle} = ChatSession.send_stream(session, "question", opts)
            output = Enum.to_list(stream)
            assert %ChatSession{} = finalized = ChatSession.finalize_stream(handle)

            assert Enum.map(ChatSession.messages(finalized), & &1.message) == [
                     Message.system("system"),
                     Message.user("question"),
                     Message.assistant("answer")
                   ]

            output
        end

      assert Enum.filter(output, &is_binary/1) == ["answer"]
      refute Enum.any?(output, &match?({:error, _}, &1))
      assert_receive {:tool_executed, %{"value" => "next-π"}}
      refute_received {:tool_executed, _}
      assert_receive {:continuation_admitted, context}
      assert context.failure.http_status == @contract["retryable_error"]["status"]
      refute_received {:continuation_admitted, _}
      [initial, continuation, replay] = GenServer.call(server, :requests) |> Enum.map(&encoded/1)
      {expected_initial, expected_continuation} = streaming_tool_bodies(@gateway, @row["config"])
      assert Jason.decode!(initial) == expected_initial
      assert Jason.decode!(continuation) == expected_continuation
      assert continuation == replay
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      boundary <- [:gateway, :broker],
      operation <- [:complete, :object, :legacy, :events],
      row <- @contract["cases"] do
    @gateway gateway
    @boundary boundary
    @operation operation
    @row row
    test "fidelity-v1 #{gateway} #{boundary} #{operation} #{row["name"]} exact body and admitted replay" do
      recovery = [
        max_attempts: 2,
        base_delay: 0,
        admission: fn _ -> :allow end,
        sleeper: fn _ -> :ok end
      ]

      fields = [:temperature, :num_ctx, :max_tokens, :top_p, :top_k]

      opts =
        for field <- fields,
            Map.has_key?(@row["config"], Atom.to_string(field)),
            do: {field, @row["config"][Atom.to_string(field)]}

      config = CompletionConfig.new(opts)
      baseline = server(@gateway, List.duplicate(success(@gateway, @operation), 2))
      invoke(@gateway, @operation, [Message.user("question")], config, "gpt-4o", @boundary)
      [original | additional] = GenServer.call(baseline, :requests) |> Enum.map(&encoded/1)
      assert Enum.all?(additional, &(&1 == original))
      assert Jason.decode!(original) == fidelity_body(@gateway, @operation, @row["config"])
      stop_supervised!(ScriptedTransport)

      retry =
        server(@gateway, [
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
          success(@gateway, @operation)
        ])

      invoke(
        @gateway,
        @operation,
        [Message.user("question")],
        %{config | recovery: recovery},
        "gpt-4o",
        @boundary
      )

      assert [^original, ^original] = GenServer.call(retry, :requests) |> Enum.map(&encoded/1)
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      operation <- [:complete, :legacy],
      row <- @contract["cases"] do
    @gateway gateway
    @operation operation
    @row row
    test "fidelity-v1 #{gateway} session #{operation} #{row["name"]} preserves per-send values" do
      server = server(@gateway, List.duplicate(success(@gateway, @operation), 2))

      session =
        ChatSession.new(Broker.new("gpt-4o", @gateway),
          system_prompt: "system",
          tokenizer: StubTokenizer.new!(),
          temperature: 0.6,
          max_context: 1000
        )

      opts =
        for field <- [:temperature, :num_ctx, :max_tokens, :top_p, :top_k],
            Map.has_key?(@row["config"], Atom.to_string(field)),
            do: {field, @row["config"][Atom.to_string(field)]}

      if @operation == :complete do
        assert {:ok, "answer", _} = ChatSession.send(session, "question", opts)
      else
        assert {:ok, stream, handle} = ChatSession.send_stream(session, "question", opts)
        assert "answer" in Enum.to_list(stream)
        assert %ChatSession{} = ChatSession.finalize_stream(handle)
      end

      bodies = GenServer.call(server, :requests) |> Enum.map(&(encoded(&1) |> Jason.decode!()))
      fields = Map.put_new(@row["config"], "temperature", 0.6)

      expected =
        fidelity_body(@gateway, @operation, fields)
        |> Map.put("messages", [
          %{"role" => "system", "content" => "system"},
          %{"role" => "user", "content" => "question"}
        ])
        |> Map.delete("tools")

      assert bodies != []
      assert Enum.all?(bodies, &(&1 == expected))
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    test "fidelity-v1 #{@gateway} Broker tracing retains unset and zero caller temperature" do
      server = server(@gateway, [success(@gateway, :complete), success(@gateway, :complete)])
      tracer = start_supervised!(Mojentic.Tracer.TracerSystem)
      broker = Broker.new("gpt-4o", @gateway, tracer: tracer)
      assert {:ok, "answer"} = Broker.generate(broker, [Message.user("question")])

      assert {:ok, "answer"} =
               Broker.generate(broker, [Message.user("question")], nil, %CompletionConfig{
                 temperature: 0
               })

      event_type = Mojentic.Tracer.TracerEvents.LLMCallTracerEvent
      events = Mojentic.Tracer.get_events(tracer, event_type: event_type)
      assert Enum.map(events, & &1.temperature) == [nil, 0]
      [unset, zero] = events
      refute event_type.printable_summary(unset) =~ "Temperature:"
      assert event_type.printable_summary(zero) =~ "Temperature: 0"

      [unset_body, zero_body] =
        GenServer.call(server, :requests) |> Enum.map(&(encoded(&1) |> Jason.decode!()))

      assert unset_body == Map.delete(fidelity_body(@gateway, :complete, %{}), "tools")

      assert zero_body ==
               Map.delete(fidelity_body(@gateway, :complete, %{"temperature" => 0}), "tools")
    end
  end

  for operation <- [:complete, :object, :legacy, :events] do
    @operation operation
    test "fidelity-v1 OpenAI #{@operation} unset reasoning limit and temperature stay absent" do
      server = server(OpenAI, [success(OpenAI, @operation)])
      invoke(OpenAI, @operation, [Message.user("question")], %CompletionConfig{}, "o3")
      [body] = GenServer.call(server, :requests) |> Enum.map(&(encoded(&1) |> Jason.decode!()))
      assert body == Map.put(fidelity_body(OpenAI, @operation, %{}), "model", "o3")
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    @tag :fidelity_proof
    test "#{gateway} unset parameters survive a tool continuation and admitted retry through production Req" do
      server =
        server(@gateway, [
          tool_response(@gateway),
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
          success(@gateway, :complete)
        ])

      config = %CompletionConfig{
        recovery: [
          max_attempts: 2,
          base_delay: 0,
          admission: fn _ -> :allow end,
          sleeper: fn _ -> :ok end
        ]
      }

      assert {:ok, "answer"} =
               Broker.generate(
                 Broker.new("gpt-4o", @gateway),
                 [Message.user("question")],
                 [%CountingTool{owner: self()}],
                 config
               )

      assert_receive {:tool_executed, %{"value" => "next-π"}}
      refute_received {:tool_executed, _}
      [initial, continuation, replay] = GenServer.call(server, :requests) |> Enum.map(&encoded/1)
      assert continuation == replay
      assert Jason.decode!(initial) == fidelity_body(@gateway, :complete, %{})

      assert Map.delete(Jason.decode!(continuation), "messages") ==
               Map.delete(Jason.decode!(initial), "messages")
    end
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
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
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
      refute_received {:tool_executed, _}
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
      stop_supervised!(ScriptedTransport)
      drain(:transport_request)
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
      refute_received {:tool_executed, _}
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
      assert length(disabled) == 1
      expected = expected(@gateway, @operation, "gpt-4o")
      assert Enum.all?(disabled, &(Jason.decode!(&1) == expected))
      stop_supervised!(ScriptedTransport)
      drain(:transport_request)

      retry =
        server(@gateway, [
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
          success(@gateway, @operation)
        ])

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
      stop_supervised!(ScriptedTransport)
      drain(:transport_request)

      retry =
        server(OpenAI, [
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
          success(OpenAI, @operation)
        ])

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
      stop_supervised!(ScriptedTransport)
      drain(:transport_request)

      retry =
        server(@gateway, [
          success(@gateway, :complete),
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
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
            "options" => %{},
            "stream" => @operation == :legacy
          })
        else
          expected
        end

      expected =
        if @gateway != Ollama and @operation == :legacy,
          do: Map.put(expected, "stream", true),
          else: expected

      assert Jason.decode!(first) == expected
      assert_evidence([first, second], [1, 2])
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX],
      defect <-
        [:response_end, :attempt_failed, :attempt_succeeded] ++
          for(
            key <- [:logical_request_id, :attempt_id, :wire_attempt],
            mutation <- [:missing, :corrupted, :masked],
            do: {key, mutation}
          ) do
    @gateway gateway
    @defect defect
    @tag :lifecycle_rejection_proof
    test "#{gateway} actual HTTP evidence rejects #{inspect(defect)}", %{path: path} do
      fixture =
        server(@gateway, [
          http(@contract["retryable_error"]["status"], @contract["retryable_error"]["body"]),
          success(@gateway, :complete)
        ])

      invoke(@gateway, :complete, history(path), config(path, self()), "gpt-4o")
      bodies = GenServer.call(fixture, :requests) |> Enum.map(&encoded/1)
      assert length(bodies) == 2
      assert Enum.all?(bodies, &(Jason.decode!(&1) == expected(@gateway, :complete, "gpt-4o")))
      assert hd(bodies) == List.last(bodies)
      data = %{timeline: drain(:timeline), traces: drain(:trace), lifecycle: drain(:lifecycle)}
      assert_evidence_data(data, bodies, [1, 2])
      corrupted = corrupt_evidence(data, @defect)

      assert_raise ExUnit.AssertionError, fn ->
        assert_evidence_data(corrupted, bodies, [1, 2])
      end
    end
  end

  defp corrupt_evidence(data, {key, mutation}) do
    index = Enum.find_index(data.lifecycle, &(&1.type == :attempt_failed))
    original = Enum.at(data.lifecycle, index)
    value = if key == :wire_attempt, do: 999, else: "corrupted-identity"

    metadata =
      case mutation do
        :missing -> Map.delete(original.metadata, key)
        :corrupted -> Map.put(original.metadata, key, value)
        :masked -> Map.put(original.metadata, key, "[redacted]")
      end

    corrupted = %{original | metadata: metadata}

    %{
      data
      | lifecycle: List.replace_at(data.lifecycle, index, corrupted),
        timeline:
          Enum.map(data.timeline, fn
            {:lifecycle, ^original} -> {:lifecycle, corrupted}
            event -> event
          end)
    }
  end

  defp corrupt_evidence(data, type) do
    %{data | timeline: Enum.reject(data.timeline, fn {_source, event} -> event.type == type end)}
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
              "num_predict" => 73,
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
      if gateway == Ollama, do: Map.put(body, "think", "high"), else: body

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
    server = start_supervised!({ScriptedTransport, {self(), responses}})
    assert_receive {:transport_id, port}
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

  defp success(gateway, operation) do
    provider = if gateway == Ollama, do: "ollama", else: "openai"
    http(200, @contract["responses"][provider <> "-" <> Atom.to_string(operation)])
  end

  defp fidelity_body(gateway, operation, fields) do
    fields = Map.reject(fields, fn {_key, value} -> is_nil(value) end)
    body = %{"model" => "gpt-4o", "messages" => [%{"role" => "user", "content" => "question"}]}

    body =
      if gateway == Ollama do
        options =
          for {key, value} <- fields,
              into: %{},
              do: {if(key == "max_tokens", do: "num_predict", else: key), value}

        Map.merge(body, %{"options" => options, "stream" => operation in [:legacy, :events]})
      else
        Map.merge(
          body,
          Map.take(
            fields,
            if(gateway == OpenAI,
              do: ["temperature", "max_tokens", "top_p"],
              else: ["temperature", "max_tokens", "top_p", "top_k"]
            )
          )
        )
      end

    body =
      if operation == :object do
        key = if gateway == Ollama, do: "format", else: "response_format"

        format =
          if gateway == Ollama,
            do: schema(),
            else: %{
              "type" => "json_schema",
              "json_schema" => %{"name" => "response", "schema" => schema()}
            }

        Map.put(body, key, format)
      else
        body
      end

    body =
      if gateway != Ollama and operation in [:legacy, :events],
        do: Map.put(body, "stream", true),
        else: body

    body =
      if gateway != Ollama and operation == :events,
        do: Map.put(body, "stream_options", %{"include_usage" => true}),
        else: body

    if operation in [:complete, :legacy],
      do: Map.put(body, "tools", [Jason.decode!(Jason.encode!(CountingTool.descriptor()))]),
      else: body
  end

  # Derive provider stream frames from the versioned native tool-call fixture.
  defp streaming_tool_response(gateway) do
    call = @contract["tool_call"]

    body =
      if gateway == Ollama do
        native =
          put_in(call, ["function", "arguments"], Jason.decode!(call["function"]["arguments"]))

        Jason.encode!(%{
          "message" => %{"content" => "", "tool_calls" => [native]},
          "done" => true,
          "done_reason" => "stop"
        }) <> "\n"
      else
        frame = %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"tool_calls" => [Map.put(call, "index", 0)]},
              "finish_reason" => "tool_calls"
            }
          ]
        }

        "data: " <> Jason.encode!(frame) <> "\n\ndata: [DONE]\n\n"
      end

    http(200, body)
  end

  # Expected wire documents are specified independently of production serializers.
  defp streaming_tool_bodies(gateway, fields) do
    messages = [
      %{"role" => "system", "content" => "system"},
      %{"role" => "user", "content" => "question"}
    ]

    body = %{
      "model" => "gpt-4o",
      "stream" => true,
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

    fields = Map.reject(fields, fn {_key, value} -> is_nil(value) end)

    body =
      case gateway do
        Ollama ->
          options =
            for {key, value} <- fields,
                into: %{},
                do: {if(key == "max_tokens", do: "num_predict", else: key), value}

          Map.put(body, "options", options)

        OpenAI ->
          Map.merge(body, Map.take(fields, ["temperature", "max_tokens", "top_p"]))

        OMLX ->
          Map.merge(body, Map.take(fields, ["temperature", "max_tokens", "top_p", "top_k"]))
      end

    call =
      if gateway == Ollama do
        %{
          "type" => "function",
          "function" => %{"name" => "count", "arguments" => %{"value" => "next-π"}}
        }
      else
        %{
          "id" => "next-id",
          "type" => "function",
          "function" => %{"name" => "count", "arguments" => "{\"value\":\"next-π\"}"}
        }
      end

    result = %{"role" => "tool", "content" => "\"tool-result-secret\""}

    result =
      if gateway == Ollama,
        do: Map.put(result, "tool_calls", [call]),
        else: Map.put(result, "tool_call_id", "next-id")

    continuation =
      Map.put(
        body,
        "messages",
        messages ++
          [
            %{"role" => "assistant", "content" => "", "tool_calls" => [call]},
            result
          ]
      )

    {body, continuation}
  end

  defp tool_response(gateway) do
    call = @contract["tool_call"]

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
    data = %{timeline: drain(:timeline), traces: drain(:trace), lifecycle: drain(:lifecycle)}
    assert_evidence_data(data, bodies, attempts)
    assert_rejects_corrupted_evidence(data, bodies, attempts)
    assert_receive {:admitted, context}
    requests = Enum.filter(data.traces, &(&1.type == :request))
    [first, _second] = Enum.take(requests, -2)
    assert context.failure.attempt_id == first.ids.attempt_id
  end

  defp assert_evidence_data(data, bodies, attempts) do
    %{timeline: timeline, traces: traces, lifecycle: lifecycle} = data
    requests = Enum.filter(traces, &(&1.type == :request))
    assert Enum.map(requests, & &1.body) == bodies
    assert Enum.map(requests, & &1.ids.wire_attempt) == attempts
    assert_attempt_ids(requests, lifecycle)
    assert for({:lifecycle, event} <- timeline, do: event) == lifecycle
    assert for({:trace, event} <- timeline, do: event) == traces
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
  end

  defp assert_rejects_corrupted_evidence(data, bodies, attempts) do
    for {event, index} <- Enum.with_index(data.lifecycle),
        event.type != :attempt_started,
        key <- [:logical_request_id, :attempt_id, :wire_attempt],
        mutation <- [:missing, :corrupted, :masked] do
      value = if key == :wire_attempt, do: 999, else: "corrupted-identity"

      metadata =
        case mutation do
          :missing -> Map.delete(event.metadata, key)
          :corrupted -> Map.put(event.metadata, key, value)
          :masked -> Map.put(event.metadata, key, "[redacted]")
        end

      corrupted =
        put_in(
          data,
          [:lifecycle],
          List.replace_at(data.lifecycle, index, %{event | metadata: metadata})
        )

      assert_raise ExUnit.AssertionError, fn ->
        assert_evidence_data(corrupted, bodies, attempts)
      end
    end

    for type <- [:response_end, :attempt_failed, :attempt_succeeded] do
      corrupted = %{
        data
        | timeline: Enum.reject(data.timeline, fn {_source, event} -> event.type == type end)
      }

      assert_raise ExUnit.AssertionError, fn ->
        assert_evidence_data(corrupted, bodies, attempts)
      end
    end
  end

  defp assert_attempt_ids(requests, lifecycle) do
    [failed, next] = Enum.take(requests, -2)

    expected =
      Enum.flat_map(requests, fn request ->
        types =
          if request == failed do
            [
              :attempt_started,
              :attempt_failed,
              :admission_pending,
              :admission_allowed,
              :backoff_started,
              :retry_started
            ]
          else
            [:attempt_started, :attempt_succeeded]
          end

        Enum.map(types, &{&1, request.ids})
      end)

    actual =
      Enum.map(lifecycle, fn event ->
        {event.type, Map.take(event.metadata, [:logical_request_id, :attempt_id, :wire_attempt])}
      end)

    assert actual == expected
    assert length(Enum.uniq(Enum.map(requests, & &1.ids.attempt_id))) == length(requests)
    assert failed.ids.logical_request_id == next.ids.logical_request_id
    assert next.ids.wire_attempt == failed.ids.wire_attempt + 1

    retry = Enum.filter(lifecycle, &(&1.type == :retry_started))
    assert length(retry) == 1
    assert hd(retry).metadata.next_attempt == next.ids.wire_attempt
    assert hd(retry).metadata.attempt_id == failed.ids.attempt_id
    refute hd(retry).metadata.attempt_id == next.ids.attempt_id
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

    assert Enum.count(order, &(&1 == :response_end)) == 1
    assert Enum.count(order, &(&1 == ending)) == 1
    response_end = Enum.find_index(order, &(&1 == :response_end))
    terminal = Enum.find_index(order, &(&1 == ending))
    assert is_integer(response_end)
    assert is_integer(terminal)
    assert response_end < terminal

    events = Enum.filter(traces, &(&1.ids == request.ids))
    assert hd(events).type == :request
    assert List.last(events).type == :response_end
    assert Enum.count(events, &(&1.type == :request)) == 1
    assert Enum.count(events, &(&1.type == :response_end)) == 1
  end
end
