defmodule Mojentic.LLM.ReasoningWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{
    Broker,
    ChatSession,
    CompletionConfig,
    CompletionError,
    Message,
    ReasoningProfile
  }

  alias Mojentic.LLM.Gateways.{Ollama, OMLX, OpenAI}
  alias Mojentic.TestSupport.{CountingTool, ScriptedCompletionServer}

  @external_resource "test/contracts/native_reasoning_v1.json"
  @contract Jason.decode!(File.read!(@external_resource))
  @efforts %{
    nil => nil,
    "disabled" => :disabled,
    "enabled" => :enabled,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh
  }

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)

    saved =
      Map.new(
        ["OMLX_HOST", "OLLAMA_HOST", "OPENAI_API_ENDPOINT", "OPENAI_API_KEY"],
        &{&1, System.get_env(&1)}
      )

    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)

      for {key, value} <- saved do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  @tag :reasoning_proof
  test "completed native reasoning and exact tool identity survive a real Req continuation" do
    tool_call = @contract["tool_call"]

    first =
      reply(
        %{
          content: "checking",
          reasoning_content: "private deliberation",
          tool_calls: [tool_call]
        },
        "tool_calls"
      )

    last = reply(%{content: "answer", reasoning_content: "final thought"}, "stop")
    server = start_supervised!({ScriptedCompletionServer, {self(), [first, last]}})
    assert_receive {:server_port, port}
    System.put_env("OMLX_HOST", "http://127.0.0.1:#{port}")
    config = %CompletionConfig{preserve_reasoning: true}

    assert {:ok, "answer"} =
             Broker.generate(
               Broker.new("unrelated-name", OMLX),
               [Message.user("question")],
               [%CountingTool{owner: self()}],
               config
             )

    assert_receive {:tool_executed, %{"value" => 7}}
    refute_receive {:tool_executed, _}
    assert [initial, continuation] = GenServer.call(server, :requests) |> Enum.map(&body/1)
    assert initial["messages"] == [%{"role" => "user", "content" => "question"}]
    assert Map.delete(continuation, "messages") == Map.delete(initial, "messages")

    assert continuation["messages"] == [
             %{"role" => "user", "content" => "question"},
             %{
               "role" => "assistant",
               "content" => "checking",
               "reasoning_content" => "private deliberation",
               "tool_calls" => [Jason.decode!(Jason.encode!(tool_call))]
             },
             %{
               "role" => "tool",
               "tool_call_id" => "call-native",
               "content" => Jason.encode!("tool-result-secret")
             }
           ]

    assert initial["chat_template_kwargs"] == %{"preserve_thinking" => true}
    assert continuation["chat_template_kwargs"] == initial["chat_template_kwargs"]
  end

  for gateway <- [Ollama, OMLX],
      boundary <- [:gateway, :broker],
      operation <- [:complete, :object, :stream, :events],
      control <- @contract["controls"] do
    @boundary boundary
    @gateway gateway
    @operation operation
    @control control
    test "#{inspect(gateway)} #{boundary} #{operation} sends exact #{inspect(control["effort"])} control and native history" do
      gateway = @gateway
      server = server(gateway, [successful_response(gateway, @operation)])

      config = %CompletionConfig{
        reasoning_effort: @efforts[@control["effort"]],
        recovery: legacy_control_recovery(gateway, @operation)
      }

      history = [
        %Message{role: :assistant, content: "visible", reasoning_content: "native"},
        Message.user("next")
      ]

      result = invoke_boundary(@boundary, gateway, @operation, history, config)
      assert_success(result, @operation)
      assert [request] = requests(server)
      provider = provider_name(gateway)

      assert Map.take(request, ["think", "enable_thinking", "reasoning_effort"]) ==
               @control[provider]

      key = history_key(gateway)

      assert request["messages"] == [
               %{"role" => "assistant", "content" => "visible", key => "native"},
               %{"role" => "user", "content" => "next"}
             ]

      refute Map.has_key?(request, "chat_template_kwargs")
    end
  end

  for gateway <- [Ollama, OMLX],
      boundary <- [:gateway, :broker],
      operation <- [:complete, :object, :stream, :events] do
    @boundary boundary
    @gateway gateway
    @operation operation
    test "#{inspect(gateway)} #{boundary} #{@operation} validates caller-selected profile before HTTP" do
      server = server(@gateway, [])

      for effort <- [:enabled, :high] do
        config = %CompletionConfig{
          reasoning_profile: ReasoningProfile.qwen3_8(),
          reasoning_effort: effort
        }

        error = {:error, {:unsupported_reasoning_effort, "qwen3.8", effort}}

        assert invoke_boundary(@boundary, @gateway, @operation, [Message.user("x")], config) ==
                 stream_error(error, @operation)
      end

      profile = %ReasoningProfile{
        name: "boolean",
        supported_efforts: [:disabled, :enabled],
        supports_reasoning_history: false
      }

      error = {:error, {:unsupported_reasoning_history, "boolean"}}
      config = %CompletionConfig{reasoning_profile: profile, preserve_reasoning: true}

      assert invoke_boundary(@boundary, @gateway, @operation, [], config) ==
               stream_error(error, @operation)

      assert requests(server) == []
    end
  end

  for gateway <- [Ollama, OMLX], effort <- [nil, :disabled, :low, :medium, :xhigh] do
    @gateway gateway
    @effort effort
    test "#{inspect(gateway)} Qwen3.8 accepts exact #{inspect(effort)} on an unrelated model name" do
      server = server(@gateway, [successful_response(@gateway, :complete)])

      config = %CompletionConfig{
        reasoning_profile: ReasoningProfile.qwen3_8(),
        reasoning_effort: @effort,
        preserve_reasoning: true
      }

      assert {:ok, _} = invoke(@gateway, :complete, [], config)
      assert [request] = requests(server)

      if @effort == nil,
        do: assert(Map.take(request, ["think", "enable_thinking", "reasoning_effort"]) == %{})
    end
  end

  for operation <- [:complete, :object, :stream, :events] do
    @operation operation
    test "OpenAI #{@operation} explicitly rejects new controls and native history before HTTP" do
      server = server(OpenAI, [])

      for opts <- [
            [preserve_reasoning: true],
            [reasoning_profile: ReasoningProfile.qwen3_8()],
            [reasoning_effort: :disabled],
            [reasoning_effort: :enabled],
            [reasoning_effort: :xhigh]
          ] do
        error = {:error, :unsupported_openai_reasoning_controls}

        assert invoke(OpenAI, @operation, [], CompletionConfig.new(opts)) ==
                 stream_error(error, @operation)
      end

      assert invoke(
               OpenAI,
               @operation,
               [%Message{role: :assistant, reasoning_content: "native"}],
               %CompletionConfig{}
             ) ==
               stream_error({:error, :unsupported_openai_reasoning_controls}, @operation)

      assert requests(server) == []
    end
  end

  for gateway <- [Ollama, OMLX], operation <- [:complete, :stream], preserve <- [false, true] do
    @gateway gateway
    @operation operation
    @preserve preserve
    test "#{inspect(gateway)} #{operation} tool continuation retains native reasoning only with preserve=#{preserve}" do
      server =
        server(@gateway, [
          tool_response(@gateway, @operation),
          successful_response(@gateway, @operation)
        ])

      config = %CompletionConfig{
        preserve_reasoning: @preserve,
        recovery: continuation_recovery(@operation, @preserve)
      }

      broker = Broker.new("unrelated-name", @gateway)
      tools = [%CountingTool{owner: self(), result: {:ok, @contract["tool_result"]}}]

      if @operation == :stream do
        events =
          Broker.generate_stream(broker, [Message.user("question")], tools, config)
          |> Enum.to_list()

        assert Enum.filter(events, &is_binary/1) == ["checking", "answer"]
        assert {:thinking, @contract["reasoning"]} in events
      else
        assert {:ok, "answer"} =
                 Broker.generate(broker, [Message.user("question")], tools, config)
      end

      assert_receive {:tool_executed, %{"value" => 7}}
      refute_receive {:tool_executed, _}
      assert [first, next] = requests(server)
      assert first["messages"] == [%{"role" => "user", "content" => "question"}]
      assert Map.delete(next, "messages") == Map.delete(first, "messages")
      key = if @gateway == Ollama, do: "thinking", else: "reasoning_content"

      call =
        if @gateway == Ollama,
          do: %{
            "type" => "function",
            "function" => %{"name" => "count", "arguments" => %{"value" => 7}}
          },
          else: @contract["tool_call"]

      assistant = %{"role" => "assistant", "content" => "checking", "tool_calls" => [call]}

      assistant =
        if @preserve, do: Map.put(assistant, key, @contract["reasoning"]), else: assistant

      tool = %{"role" => "tool", "content" => Jason.encode!(@contract["tool_result"])}

      tool =
        if @gateway == OMLX,
          do: Map.put(tool, "tool_call_id", "call-native"),
          else: Map.put(tool, "tool_calls", [call])

      assert next["messages"] == [%{"role" => "user", "content" => "question"}, assistant, tool]

      if @gateway == OMLX do
        expected = if @preserve, do: %{"preserve_thinking" => true}, else: nil
        assert first["chat_template_kwargs"] == expected
        assert next["chat_template_kwargs"] == expected
      end
    end
  end

  for gateway <- [Ollama, OMLX], failure <- [:interrupted, :length, :cancelled] do
    @gateway gateway
    @failure failure
    test "#{inspect(gateway)} #{@failure} stream never executes tools or fabricates a continuation" do
      response = failed_stream(@gateway, @failure)
      server = server(@gateway, [response])

      session =
        ChatSession.new(Broker.new("unrelated-name", @gateway),
          tools: [%CountingTool{owner: self()}]
        )

      assert {:ok, stream, handle} =
               ChatSession.send_stream(session, "question", preserve_reasoning: true)

      events =
        if @failure == :cancelled, do: halt_after_reasoning(stream), else: Enum.to_list(stream)

      if @failure == :cancelled do
        assert {:thinking, @contract["reasoning"]} in events
        assert ChatSession.finalize_stream(handle) == {:error, :consumer_halted}
      else
        assert Enum.any?(events, &match?({:error, %CompletionError{}}, &1))
        assert {:error, %CompletionError{}} = ChatSession.finalize_stream(handle)
      end

      refute_receive {:tool_executed, _}
      assert [_initial] = requests(server)
      assert Enum.all?(ChatSession.messages(session), &(&1.message.reasoning_content == nil))
    end
  end

  test "ChatSession ordinary and stream paths forward exact controls and validate profiles" do
    server =
      server(OMLX, [successful_response(OMLX, :complete), successful_response(OMLX, :stream)])

    session = ChatSession.new(Broker.new("unrelated-name", OMLX))

    opts = [
      reasoning_effort: :xhigh,
      reasoning_profile: ReasoningProfile.qwen3_8(),
      preserve_reasoning: true
    ]

    assert {:ok, "answer", session} = ChatSession.send(session, "first", opts)
    assert {:ok, stream, handle} = ChatSession.send_stream(session, "next", opts)
    assert "answer" in Enum.to_list(stream)
    assert %ChatSession{} = ChatSession.finalize_stream(handle)
    assert [first, next] = requests(server)
    assert first["reasoning_effort"] == "xhigh"
    assert next["reasoning_effort"] == "xhigh"
    assert first["chat_template_kwargs"] == %{"preserve_thinking" => true}

    assert {:error, {:unsupported_reasoning_effort, "qwen3.8", :high}} =
             ChatSession.send(session, "invalid", Keyword.put(opts, :reasoning_effort, :high))

    assert requests(server) == [first, next]
  end

  for gateway <- [Ollama, OMLX], operation <- [:complete, :object, :stream, :events] do
    @gateway gateway
    @operation operation
    test "#{inspect(gateway)} #{operation} requests native retention without inventing effort" do
      server = server(@gateway, [successful_response(@gateway, @operation)])
      config = %CompletionConfig{preserve_reasoning: true}
      assert_success(invoke(@gateway, @operation, [Message.user("x")], config), @operation)
      assert [request] = requests(server)
      assert Map.take(request, ["think", "enable_thinking", "reasoning_effort"]) == %{}
      assert_retention_request(@gateway, request)
    end
  end

  for gateway <- [Ollama, OMLX] do
    @gateway gateway
    test "#{inspect(gateway)} legacy stream exposes native reasoning separately through validated Req" do
      server = server(@gateway, [tool_response(@gateway, :stream)])

      events =
        invoke(@gateway, :stream, [Message.user("x")], %CompletionConfig{
          recovery: legacy_control_recovery(@gateway, :stream)
        })
        |> Enum.reject(fn {kind, _} -> kind in [:progress, :metrics] end)

      assert [
               {:thinking, "private deliberation"},
               {:content, "checking"},
               {:tool_calls, [call]},
               {:completed, %{metadata: %{first_token_kind: :thinking}}}
             ] =
               events

      assert call.id == "call-native"
      assert call.name == "count"
      assert call.arguments == %{"value" => 7}
      assert [_request] = requests(server)
    end
  end

  for effort <- [nil, :low, :medium, :high] do
    @effort effort
    test "OpenAI preserves legacy #{inspect(effort)} effort and history through Req" do
      server = server(OpenAI, [successful_response(OMLX, :complete)])
      messages = [Message.assistant("prior"), Message.user("next")]
      config = %CompletionConfig{reasoning_effort: @effort}
      assert {:ok, _} = OpenAI.complete("o3", messages, nil, config)
      assert [request] = requests(server)

      assert request["messages"] == [
               %{"role" => "assistant", "content" => "prior"},
               %{"role" => "user", "content" => "next"}
             ]

      expected = if @effort, do: to_string(@effort)
      assert request["reasoning_effort"] == expected
      refute Map.has_key?(request, "chat_template_kwargs")
      refute Map.has_key?(request, "enable_thinking")
    end
  end

  test "invalid reasoning configuration fails before HTTP" do
    server = server(OMLX, [])

    for config <- [
          %CompletionConfig{reasoning_effort: :unknown},
          %CompletionConfig{preserve_reasoning: nil},
          %CompletionConfig{reasoning_profile: %{}},
          %CompletionConfig{
            reasoning_profile: %ReasoningProfile{
              name: "invalid",
              supported_efforts: nil,
              supports_reasoning_history: true
            }
          }
        ] do
      assert {:error, _} = OMLX.complete("unrelated-name", [], nil, config)
    end

    assert requests(server) == []
  end

  for gateway <- [Ollama, OMLX] do
    @gateway gateway
    test "#{inspect(gateway)} incomplete ordinary native turn cannot execute tools or retain history" do
      message = %{content: "partial", tool_calls: [@contract["tool_call"]]}

      response =
        if @gateway == Ollama,
          do: response(Jason.encode!(%{message: message, done: true, done_reason: "length"})),
          else: reply(message, "length")

      server = server(@gateway, [response])
      config = %CompletionConfig{preserve_reasoning: true}

      assert {:error, {:incomplete_completion, "length"}} =
               Broker.generate(
                 Broker.new("unrelated-name", @gateway),
                 [Message.user("x")],
                 [%CountingTool{owner: self()}],
                 config
               )

      refute_receive {:tool_executed, _}
      assert [_request] = requests(server)
    end
  end

  test "legacy ChatSession stores visible content separately from native stream reasoning" do
    server =
      server(OMLX, [
        encode_response(OMLX, :stream, %{content: "answer", reasoning_content: "native"}, "stop")
      ])

    session = ChatSession.new(Broker.new("unrelated-name", OMLX))
    assert {:ok, stream, handle} = ChatSession.send_stream(session, "question")

    assert [
             {:thinking, "native"},
             "answer",
             {:completed, %{metadata: %{first_token_kind: :thinking}}}
           ] = Enum.to_list(stream)

    session = ChatSession.finalize_stream(handle)
    assert List.last(ChatSession.messages(session)).message == Message.assistant("answer")
    assert [_request] = requests(server)
  end

  for gateway <- [Ollama, OMLX], operation <- [:complete, :stream] do
    @gateway gateway
    @operation operation
    test "#{inspect(gateway)} #{operation} retention leaves absent native reasoning omitted" do
      server =
        server(@gateway, [
          tool_response(@gateway, @operation, nil),
          successful_response(@gateway, @operation)
        ])

      broker = Broker.new("unrelated-name", @gateway)
      tools = [%CountingTool{owner: self()}]
      config = %CompletionConfig{preserve_reasoning: true}

      if @operation == :stream do
        events =
          Broker.generate_stream(broker, [Message.user("question")], tools, config)
          |> Enum.to_list()

        refute Enum.any?(events, &match?({:thinking, _}, &1))
      else
        assert {:ok, "answer"} =
                 Broker.generate(broker, [Message.user("question")], tools, config)
      end

      assert_receive {:tool_executed, %{"value" => 7}}
      assert [_first, next] = requests(server)
      assert [_, assistant, _] = next["messages"]
      refute Map.has_key?(assistant, history_key(@gateway))
    end
  end

  defp halt_after_reasoning(stream) do
    Enum.reduce_while(stream, [], fn
      {:thinking, _text} = event, events -> {:halt, Enum.reverse([event | events])}
      event, events -> {:cont, [event | events]}
    end)
  end

  for gateway <- [Ollama, OMLX] do
    @gateway gateway
    @tag :structured_reasoning
    test "#{inspect(gateway)} structured response keeps native reasoning outside the JSON object" do
      content = Jason.encode!(%{answer: "structured"})
      key = if @gateway == Ollama, do: :thinking, else: :reasoning_content
      message = Map.put(%{content: content}, key, "native structured")
      server = server(@gateway, [encode_response(@gateway, :object, message, "stop")])
      assert {:ok, response} = invoke(@gateway, :object, [Message.user("x")], %CompletionConfig{})
      assert response.object == %{"answer" => "structured"}
      assert response.content == content
      assert response.thinking == "native structured"
      assert [_request] = requests(server)
    end
  end

  defp legacy_control_recovery(Ollama, :stream), do: []
  defp legacy_control_recovery(_gateway, _operation), do: nil

  defp continuation_recovery(:stream, false), do: []
  defp continuation_recovery(_operation, _preserve), do: nil

  defp assert_retention_request(OMLX, request),
    do: assert(request["chat_template_kwargs"] == %{"preserve_thinking" => true})

  defp assert_retention_request(Ollama, request),
    do: refute(Map.has_key?(request, "chat_template_kwargs"))

  defp provider_name(Ollama), do: "ollama"
  defp provider_name(OMLX), do: "omlx"
  defp history_key(Ollama), do: "thinking"
  defp history_key(OMLX), do: "reasoning_content"

  defp server(gateway, responses) do
    server = start_supervised!({ScriptedCompletionServer, {self(), responses}})
    assert_receive {:server_port, port}
    host = "http://127.0.0.1:#{port}"

    case gateway do
      OMLX ->
        System.put_env("OMLX_HOST", host)

      Ollama ->
        System.put_env("OLLAMA_HOST", host)

      OpenAI ->
        System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
        System.put_env("OPENAI_API_KEY", "fixture-key")
    end

    server
  end

  defp requests(server), do: GenServer.call(server, :requests) |> Enum.map(&body/1)

  defp invoke_boundary(:gateway, gateway, operation, messages, config),
    do: invoke(gateway, operation, messages, config)

  defp invoke_boundary(:broker, gateway, operation, messages, config) do
    broker = Broker.new("unrelated-name", gateway)

    case operation do
      :complete -> Broker.generate(broker, messages, nil, config)
      :object -> Broker.generate_object(broker, messages, %{}, config)
      :stream -> Broker.generate_stream(broker, messages, nil, config) |> Enum.to_list()
      :events -> Broker.generate_stream_events(broker, messages, config) |> Enum.to_list()
    end
  end

  defp invoke(gateway, :complete, messages, config),
    do: gateway.complete("unrelated-name", messages, nil, config)

  defp invoke(gateway, :object, messages, config),
    do: gateway.complete_object("unrelated-name", messages, %{}, config)

  defp invoke(gateway, :stream, messages, config),
    do: gateway.complete_stream("unrelated-name", messages, nil, config) |> Enum.to_list()

  defp invoke(gateway, :events, messages, config),
    do: gateway.complete_stream_events("unrelated-name", messages, config) |> Enum.to_list()

  defp stream_error(error, operation) when operation in [:stream, :events], do: [error]
  defp stream_error(error, _), do: error

  defp assert_success(result, operation) when operation in [:stream, :events],
    do: refute(Enum.any?(result, &match?({:error, _}, &1)))

  defp assert_success(result, _), do: assert(match?({:ok, _}, result))

  defp successful_response(gateway, operation) do
    text = if operation == :object, do: "{}", else: @contract["answer"]
    message = %{content: text}
    encode_response(gateway, operation, message, "stop")
  end

  defp tool_response(gateway, operation, reasoning \\ @contract["reasoning"]) do
    call = @contract["tool_call"]

    call =
      if gateway == Ollama,
        do: put_in(call, ["function", "arguments"], %{"value" => 7}),
        else: Map.put(call, "index", 0)

    message = %{content: @contract["visible"], tool_calls: [call]}
    key = if gateway == Ollama, do: :thinking, else: :reasoning_content

    message = if reasoning == nil, do: message, else: Map.put(message, key, reasoning)
    encode_response(gateway, operation, message, "tool_calls")
  end

  defp encode_response(Ollama, operation, message, finish) when operation in [:stream, :events] do
    # Ollama's successful tool terminal is stop, not OpenAI's tool_calls.
    terminal = if finish == "tool_calls", do: "stop", else: finish

    response(
      Jason.encode!(%{model: "fixture", done: false, message: message}) <>
        "\n" <>
        Jason.encode!(%{model: "fixture", done: true, done_reason: terminal, message: %{}}) <>
        "\n"
    )
  end

  defp encode_response(Ollama, _operation, message, _finish),
    do: response(Jason.encode!(%{message: message, done: true, done_reason: "stop"}))

  defp encode_response(OMLX, operation, message, finish) when operation in [:stream, :events] do
    response(
      sse(%{model: "fixture", choices: [%{index: 0, delta: message, finish_reason: nil}]}) <>
        sse(%{model: "fixture", choices: [%{index: 0, delta: %{}, finish_reason: finish}]}) <>
        "data: [DONE]\n\n"
    )
  end

  defp encode_response(OMLX, _operation, message, finish), do: reply(message, finish)
  defp sse(frame), do: "data: " <> Jason.encode!(frame) <> "\n\n"

  defp failed_stream(gateway, :cancelled), do: tool_response(gateway, :stream)

  defp failed_stream(Ollama, failure) do
    terminal =
      if failure == :length,
        do: Jason.encode!(%{done: true, done_reason: "length", message: %{}}) <> "\n",
        else: ""

    message = %{
      thinking: @contract["reasoning"],
      content: "partial",
      tool_calls: [put_in(@contract["tool_call"], ["function", "arguments"], %{"value" => 7})]
    }

    response(Jason.encode!(%{done: false, message: message}) <> "\n" <> terminal)
  end

  defp failed_stream(OMLX, failure) do
    terminal =
      if failure == :length,
        do: sse(%{choices: [%{delta: %{}, finish_reason: "length"}]}) <> "data: [DONE]\n\n",
        else: ""

    response(
      sse(%{
        choices: [
          %{
            delta: %{
              reasoning_content: @contract["reasoning"],
              tool_calls: [Map.put(@contract["tool_call"], "index", 0)]
            }
          }
        ]
      }) <> terminal
    )
  end

  defp reply(message, finish),
    do: response(Jason.encode!(%{choices: [%{message: message, finish_reason: finish}]}))

  defp response(body),
    do:
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

  defp body(request),
    do: request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()
end
