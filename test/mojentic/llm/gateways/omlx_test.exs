defmodule Mojentic.LLM.Gateways.OMLXTest do
  # Not async: these tests set OMLX_* environment variables.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Mojentic.LLM.{Broker, CompletionConfig, GatewayResponse, Message, ToolCall}
  alias Mojentic.LLM.Gateways.OMLX
  alias Mojentic.TestSupport.ChunkedHTTPServer

  setup :verify_on_exit!

  @fixtures_dir Path.join([__DIR__, "..", "..", "..", "fixtures", "omlx"])
  @env_keys ["OMLX_HOST", "OMLX_API_KEY", "OMLX_TIMEOUT"]
  @model "Qwen3.8-27B-MLX-8bit"
  @schema %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}, "age" => %{"type" => "integer"}}
  }
  @warning ~s(199 omlx "json_schema grammar unavailable; enforced by prompt instructions")

  defmodule ResolveDateTool do
    @moduledoc false
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args) do
      send(self(), {:resolve_date_called, args})
      {:ok, %{"date" => "2026-09-29"}}
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "resolve_date",
          description: "Resolve a relative date",
          parameters: %{
            type: "object",
            properties: %{relative: %{type: "string"}},
            required: ["relative"]
          }
        }
      }
    end

    def matches?(name), do: name == "resolve_date"
  end

  setup do
    saved = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "configuration" do
    test "defaults to localhost:8000 under /v1, the OpenAI timeout, and no authorization" do
      expect_post(fixture("chat_thinking.json"))

      assert {:ok, _} = OMLX.complete(@model, [Message.user("hi")], nil, CompletionConfig.new())

      assert_received {:post, url, _body, headers, opts}
      assert url == "http://localhost:8000/v1/chat/completions"
      assert header(headers, "authorization") == nil
      assert header(headers, "content-type") == "application/json"
      assert opts[:recv_timeout] == 60_000
    end

    test "OMLX_HOST, OMLX_API_KEY and OMLX_TIMEOUT configure every request" do
      System.put_env("OMLX_HOST", "http://studio.local:9000/")
      System.put_env("OMLX_API_KEY", "local-key")
      System.put_env("OMLX_TIMEOUT", "1234")
      expect_post(fixture("chat_thinking.json"))

      assert {:ok, _} = OMLX.complete(@model, [Message.user("hi")], nil, CompletionConfig.new())

      assert_received {:post, url, _body, headers, opts}
      assert url == "http://studio.local:9000/v1/chat/completions"
      assert header(headers, "authorization") == "Bearer local-key"
      assert opts[:recv_timeout] == 1234
    end

    test "an empty OMLX_API_KEY sends no authorization header" do
      System.put_env("OMLX_API_KEY", "")
      expect_get(fixture("models.json"))

      assert {:ok, _} = OMLX.get_available_models()

      assert_received {:get, _url, headers, _opts}
      assert header(headers, "authorization") == nil
    end

    test "an unparseable OMLX_TIMEOUT falls back to the default" do
      System.put_env("OMLX_TIMEOUT", "soon")
      expect_get(fixture("models.json"))

      assert {:ok, _} = OMLX.get_available_models()

      assert_received {:get, _url, _headers, opts}
      assert opts[:recv_timeout] == 60_000
    end
  end

  describe "chat request body" do
    test "sends each configured field unchanged, even for a name OpenAI treats as reasoning" do
      config =
        CompletionConfig.new(
          temperature: 0.2,
          max_tokens: 512,
          num_predict: 99,
          top_p: 0.9,
          top_k: 40,
          reasoning_effort: :high
        )

      expect_post(fixture("chat_thinking.json"))

      assert {:ok, _} =
               OMLX.complete("o3-local-mlx", [Message.user("hi")], [ResolveDateTool], config)

      assert_received {:post, _url, body, _headers, _opts}

      assert body == %{
               "model" => "o3-local-mlx",
               "messages" => [%{"role" => "user", "content" => "hi"}],
               "temperature" => 0.2,
               "max_tokens" => 512,
               "top_p" => 0.9,
               "top_k" => 40,
               "reasoning_effort" => "high",
               "tools" => [json(ResolveDateTool.descriptor())]
             }
    end

    test "omits unset optional fields and never sends context settings" do
      expect_post(fixture("chat_thinking.json"))

      assert {:ok, _} = OMLX.complete(@model, [Message.user("hi")], [], CompletionConfig.new())

      assert_received {:post, _url, body, _headers, _opts}
      assert Enum.sort(Map.keys(body)) == ["max_tokens", "messages", "model", "temperature"]
    end

    test "forwards each response format as an OpenAI-compatible value" do
      formats = [
        {%{type: :text}, %{"type" => "text"}},
        {%{type: :json_object, schema: nil}, %{"type" => "json_object"}},
        {%{type: :json_object, schema: @schema},
         %{"type" => "json_schema", "json_schema" => %{"name" => "response", "schema" => @schema}}}
      ]

      for {format, expected} <- formats do
        expect_post(fixture("chat_json_schema.json"))
        config = CompletionConfig.new(response_format: format)

        assert {:ok, _} = OMLX.complete(@model, [Message.user("hi")], nil, config)

        assert_received {:post, _url, body, _headers, _opts}
        assert body["response_format"] == expected
      end
    end
  end

  describe "chat responses" do
    test "reasoning_content maps to thinking, and usage is kept exactly as reported" do
      reported = decoded("chat_thinking.json")
      expect_post(fixture("chat_thinking.json"))

      assert {:ok, %GatewayResponse{} = response} =
               OMLX.complete(@model, [Message.user("hi")], nil, CompletionConfig.new())

      assert response.content == "hello"
      assert response.thinking == message(reported)["reasoning_content"]
      assert response.usage == reported["usage"]
      assert response.usage["model_load_duration"] == 8.78
      assert response.model == @model
      assert response.finish_reason == "stop"
      assert response.tool_calls == []
      assert response.metadata == %{}
    end

    test "a response without reasoning_content has no thinking" do
      expect_post(fixture("chat_thinking_disabled.json"))

      assert {:ok, response} =
               OMLX.complete(@model, [Message.user("hi")], nil, CompletionConfig.new())

      assert response.content == "hello"
      assert response.thinking == nil
    end

    test "tool calls are parsed as the OpenAI gateway parses them" do
      expect_post(fixture("chat_tool_call.json"))

      assert {:ok, response} =
               OMLX.complete(
                 @model,
                 [Message.user("date?")],
                 [ResolveDateTool],
                 CompletionConfig.new()
               )

      assert response.tool_calls == [
               %ToolCall{
                 id: "call_bd4d55c2",
                 name: "resolve_date",
                 arguments: %{"relative" => "today"}
               }
             ]

      assert response.content == nil
      assert response.thinking =~ "resolve_date tool"
      assert response.finish_reason == "tool_calls"
    end

    test "a tool result round trip threads the call and its result back to the server" do
      expect_post(fixture("chat_tool_call.json"))
      expect_post(fixture("chat_after_tool_result.json"))

      assert {:ok, "Today's date is **September 29, 2026** (2026-09-29)."} =
               Broker.generate(
                 Broker.new(@model, OMLX),
                 [Message.user("What is today's date? Use the tool.")],
                 [ResolveDateTool]
               )

      assert_received {:resolve_date_called, %{"relative" => "today"}}
      assert_received {:post, _url, first, _headers, _opts}
      assert [%{"function" => %{"name" => "resolve_date"}}] = first["tools"]

      assert_received {:post, _url, second, _headers, _opts}
      assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))

      assert [%{"id" => "call_bd4d55c2", "function" => %{"arguments" => arguments}}] =
               assistant["tool_calls"]

      assert Jason.decode!(arguments) == %{"relative" => "today"}

      tool = Enum.find(second["messages"], &(&1["role"] == "tool"))
      assert tool["tool_call_id"] == "call_bd4d55c2"
      assert Jason.decode!(tool["content"]) == %{"date" => "2026-09-29"}
    end

    test "truncation during thinking maps to finish reason length with content unchanged" do
      expect_post(fixture("chat_length.json"))

      assert {:ok, response} =
               OMLX.complete(
                 @model,
                 [Message.user("hi")],
                 nil,
                 CompletionConfig.new(max_tokens: 5)
               )

      assert response.finish_reason == "length"
      assert response.content == "We need to respond to"
      assert response.thinking == nil
    end

    test "provider errors carry the status and the error body" do
      for {status, body} <- [
            {404, fixture("error_model_not_found.json")},
            {401,
             ~s({"error":{"message":"Invalid API key","type":"authentication_error","param":null,"code":null}})}
          ] do
        expect_post(body, status)

        assert {:error, {:http_error, ^status, ^body}} =
                 OMLX.complete("nope", [Message.user("hi")], nil, CompletionConfig.new())
      end
    end

    test "a failed connection is a request failure" do
      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:error, :econnrefused}
      end)

      assert {:error, {:request_failed, :econnrefused}} =
               OMLX.complete(@model, [Message.user("hi")], nil, CompletionConfig.new())
    end

    test "a body without choices is an invalid response" do
      expect_post(~s({"object":"chat.completion"}))

      assert {:error, :invalid_response} =
               OMLX.complete(@model, [Message.user("hi")], nil, CompletionConfig.new())
    end
  end

  describe "structured output" do
    test "complete_object requests a json_schema response format and parses the content" do
      reported = decoded("chat_json_schema.json")
      expect_post(fixture("chat_json_schema.json"))

      assert {:ok, response} =
               OMLX.complete_object(
                 @model,
                 [Message.user("Ada, 36")],
                 @schema,
                 CompletionConfig.new()
               )

      assert_received {:post, url, body, _headers, _opts}
      assert url == "http://localhost:8000/v1/chat/completions"

      assert body["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{"name" => "response", "schema" => @schema}
             }

      refute Map.has_key?(body, "tools")
      assert response.object == %{"name" => "Ada", "age" => 36}
      assert response.content == ~s({"name": "Ada", "age": 36})
      assert response.usage == reported["usage"]
      assert response.model == @model
      assert response.finish_reason == "stop"
      assert response.metadata == %{}
    end

    test "a Warning header on a structured request is recorded in metadata and logged" do
      expect_post(fixture("chat_json_schema.json"), 200, [{"warning", @warning}])

      log =
        capture_log(fn ->
          assert {:ok, response} =
                   OMLX.complete_object(
                     @model,
                     [Message.user("Ada")],
                     @schema,
                     CompletionConfig.new()
                   )

          assert response.metadata == %{"response_format_warning" => @warning}
          assert response.object == %{"name" => "Ada", "age" => 36}
        end)

      assert log =~ @warning
    end

    test "a Warning header is recorded when complete/4 asked for JSON" do
      config = CompletionConfig.new(response_format: %{type: :json_object, schema: nil})
      expect_post(fixture("chat_json_schema.json"), 200, [{"Warning", @warning}])

      capture_log(fn ->
        assert {:ok, response} = OMLX.complete(@model, [Message.user("Ada")], nil, config)
        assert response.metadata == %{"response_format_warning" => @warning}
      end)
    end

    test "a Warning header is not response format evidence when no structure was asked for" do
      for format <- [nil, %{type: :text}] do
        expect_post(fixture("chat_thinking.json"), 200, [{"warning", @warning}])
        config = CompletionConfig.new(response_format: format)

        assert {:ok, response} = OMLX.complete(@model, [Message.user("hi")], nil, config)
        assert response.metadata == %{}
      end
    end

    test "content that is not JSON is an invalid object" do
      expect_post(fixture("chat_length.json"))

      assert {:error, :invalid_json_object} =
               OMLX.complete_object(
                 @model,
                 [Message.user("Ada")],
                 @schema,
                 CompletionConfig.new()
               )
    end

    test "structured requests report provider errors" do
      body = fixture("error_model_not_found.json")
      expect_post(body, 404)

      assert {:error, {:http_error, 404, ^body}} =
               OMLX.complete_object(
                 "nope",
                 [Message.user("Ada")],
                 @schema,
                 CompletionConfig.new()
               )
    end
  end

  describe "single-turn stream events" do
    test "a thinking stream completes with content only and the real model as evidence" do
      reported_usage = last_usage("stream_thinking.sse")
      expect_stream(chunks("stream_thinking.sse", 17))

      events =
        Broker.new(@model, OMLX)
        |> Broker.generate_stream_events([Message.user("hi")], CompletionConfig.new())
        |> Enum.to_list()

      assert events == [
               {:content, "\n\nhello"},
               {:completed,
                %{
                  finish_reason: "stop",
                  usage: reported_usage,
                  provider_model: @model,
                  metadata: nil
                }}
             ]

      assert_received {:post_stream, url, body, headers, _opts}
      assert url == "http://localhost:8000/v1/chat/completions"
      assert header(headers, "authorization") == nil
      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
      refute Map.has_key?(body, "tools")
    end

    test "a length-limited stream is an incomplete completion carrying the real model" do
      expect_stream(chunks("stream_length.sse", 23))

      assert [
               {:error,
                {:incomplete_completion,
                 %{
                   finish_reason: "length",
                   usage: %{"completion_tokens" => 5, "generation_tokens_per_second" => 15.26},
                   provider_model: @model
                 }}}
             ] = events()
    end

    test "a streamed tool call is an unexpected-tool-calls error after the real content only" do
      expect_stream(chunks("stream_tool_call.sse", 31))

      # The server sends "\n\n" content before the call. The keep-alive frame's
      # empty content yields no event.
      assert events() == [{:content, "\n\n"}, {:error, :unexpected_tool_calls}]
    end

    test "a stream of only a keep-alive frame is incomplete with no provider model" do
      expect_stream([keepalive_frame()])

      assert events() == [{:error, {:incomplete_stream, nil}}]
    end

    test "a keep-alive frame after the first real frame does not replace the reported model" do
      frame =
        "data: " <>
          Jason.encode!(%{model: @model, choices: [%{index: 0, delta: %{content: "Hel"}}]}) <>
          "\n\n"

      expect_stream([frame <> keepalive_frame()])

      assert [
               {:content, "Hel"},
               {:error, {:incomplete_stream, %{provider_model: @model}}}
             ] = events()
    end

    test "an SSE comment keep-alive is ignored" do
      expect_stream([": keep-alive\n\n" <> fixture("stream_thinking.sse")])

      assert [{:content, "\n\nhello"}, {:completed, %{provider_model: @model}}] = events()
    end

    test "a non-2xx status is a provider error" do
      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:error, {:http_error, 401}}
      end)

      assert events() == [{:error, {:provider_error, %{status: 401}}}]
    end

    test "requested formats are forwarded in the stream request" do
      config = CompletionConfig.new(response_format: %{type: :json_object, schema: @schema})
      expect_stream([])

      OMLX.complete_stream_events(@model, [Message.user("hi")], config) |> Enum.to_list()

      assert_received {:post_stream, _url, body, _headers, _opts}
      assert body["response_format"]["type"] == "json_schema"
    end
  end

  describe "single-turn stream events over real HTTP" do
    setup do
      previous = Application.get_env(:mojentic, :http_client)
      Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
      System.put_env("OMLX_TIMEOUT", "1000")
      on_exit(fn -> Application.put_env(:mojentic, :http_client, previous) end)
      :ok
    end

    test "halting after the first content event cancels the request" do
      frame =
        "data: " <>
          Jason.encode!(%{model: @model, choices: [%{index: 0, delta: %{content: "partial"}}]}) <>
          "\n\n"

      start_supervised!({ChunkedHTTPServer, {self(), [keepalive_frame(), frame], true, 200}})
      assert_receive {:port, port}
      System.put_env("OMLX_HOST", "http://127.0.0.1:#{port}")

      assert [{:content, "partial"}] = Enum.take(events(), 1)
      assert_receive {:request, request}
      assert request =~ "POST /v1/chat/completions"
      assert_receive {:cancel_result, {:error, :closed}}, 2000
    end
  end

  describe "legacy streaming" do
    test "a streamed tool call yields one complete tool call" do
      expect_stream(chunks("stream_tool_call.sse", 29))

      assert [
               {:content, "\n\n"},
               {:tool_calls,
                [
                  %ToolCall{
                    id: "call_659d0e77",
                    name: "resolve_date",
                    arguments: %{"relative" => "today"}
                  }
                ]}
             ] =
               @model
               |> OMLX.complete_stream(
                 [Message.user("date?")],
                 [ResolveDateTool],
                 CompletionConfig.new()
               )
               |> Enum.to_list()

      assert_received {:post_stream, _url, body, _headers, _opts}
      assert [%{"function" => %{"name" => "resolve_date"}}] = body["tools"]
      assert body["stream"] == true
      refute Map.has_key?(body, "stream_options")
    end

    test "reasoning is dropped and content is streamed" do
      expect_stream(chunks("stream_thinking.sse", 41))

      assert ["\n\nhello"] =
               Broker.new(@model, OMLX)
               |> Broker.generate_stream([Message.user("hi")])
               |> Enum.to_list()
    end
  end

  describe "models" do
    test "lists available model ids, sorted" do
      expect_get(fixture("models.json"))
      assert {:ok, [@model]} = OMLX.get_available_models()
      assert_received {:get, "http://localhost:8000/v1/models", _headers, _opts}

      expect_get(~s({"object":"list","data":[{"id":"zeta"},{"id":"Alpha"},{"id":"beta"}]}))
      assert {:ok, ["Alpha", "beta", "zeta"]} = OMLX.get_available_models()
    end

    test "listing models reports provider errors and invalid bodies" do
      body = ~s({"error":{"message":"Invalid API key","type":"authentication_error"}})
      expect_get(body, 401)
      assert {:error, {:http_error, 401, ^body}} = OMLX.get_available_models()

      expect_get(~s({"object":"list"}))
      assert {:error, :invalid_response} = OMLX.get_available_models()

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts -> {:error, :econnrefused} end)
      assert {:error, {:request_failed, :econnrefused}} = OMLX.get_available_models()
    end

    test "load_model posts to the model's load path with a long timeout" do
      System.put_env("OMLX_API_KEY", "local-key")
      expect_post(fixture("model_load.json"))

      assert :ok = OMLX.load_model(@model)

      assert_received {:post, url, _body, headers, opts}
      assert url == "http://localhost:8000/v1/models/#{@model}/load"
      assert header(headers, "authorization") == "Bearer local-key"
      assert opts[:recv_timeout] >= 600_000
    end

    test "unload_model posts to the model's unload path" do
      expect_post(fixture("model_unload.json"))

      assert :ok = OMLX.unload_model(@model)

      assert_received {:post, "http://localhost:8000/v1/models/Qwen3.8-27B-MLX-8bit/unload", _, _,
                       _}
    end

    test "unloading a model that is not loaded is a provider error" do
      body = fixture("error_model_not_loaded.json")
      expect_post(body, 400)

      assert {:error, {:http_error, 400, ^body}} = OMLX.unload_model(@model)
    end

    test "model ids are percent-encoded in the path" do
      expect_post(fixture("model_load.json"))

      assert :ok = OMLX.load_model("my model")

      assert_received {:post, "http://localhost:8000/v1/models/my%20model/load", _, _, _}
    end

    test "a failed connection while loading is a request failure" do
      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts -> {:error, :timeout} end)

      assert {:error, {:request_failed, :timeout}} = OMLX.load_model(@model)
    end
  end

  describe "embeddings" do
    test "sends one request with the model and text, and returns the embedding unchanged" do
      expect_post(
        ~s({"object":"list","data":[{"object":"embedding","index":0,"embedding":[3.0,-4.0]}]})
      )

      assert {:ok, [3.0, -4.0]} = OMLX.calculate_embeddings("hello world", "embed-model")

      assert_received {:post, url, body, _headers, _opts}
      assert url == "http://localhost:8000/v1/embeddings"
      assert body == %{"model" => "embed-model", "input" => "hello world"}
    end

    test "a missing model is an argument error before any request" do
      for model <- [nil, ""] do
        assert_raise ArgumentError, ~r/model/, fn -> OMLX.calculate_embeddings("hello", model) end
      end
    end

    test "a chat model is reported as a provider error" do
      body = fixture("error_not_embedding_model.json")
      expect_post(body, 400)

      assert {:error, {:http_error, 400, ^body}} = OMLX.calculate_embeddings("hello", @model)
    end

    test "a body without an embedding is an invalid response" do
      expect_post(~s({"object":"list","data":[]}))

      assert {:error, :invalid_response} = OMLX.calculate_embeddings("hello", "embed-model")
    end
  end

  defp events do
    Broker.generate_stream_events(
      Broker.new(@model, OMLX),
      [Message.user("hi")],
      CompletionConfig.new()
    )
    |> Enum.to_list()
  end

  defp expect_post(response_body, status \\ 200, headers \\ []) do
    expect(Mojentic.HTTPMock, :post, fn url, body, request_headers, opts ->
      send(self(), {:post, url, decode_body(body), request_headers, opts})
      {:ok, %{status_code: status, body: response_body, headers: headers}}
    end)
  end

  defp expect_get(response_body, status \\ 200) do
    expect(Mojentic.HTTPMock, :get, fn url, headers, opts ->
      send(self(), {:get, url, headers, opts})
      {:ok, %{status_code: status, body: response_body, headers: []}}
    end)
  end

  defp expect_stream(chunks) do
    expect(Mojentic.HTTPMock, :post_stream, fn url, body, headers, opts ->
      send(self(), {:post_stream, url, Jason.decode!(body), headers, opts})
      {:ok, Enum.map(chunks, &{:data, &1})}
    end)
  end

  defp decode_body(""), do: nil
  defp decode_body(body), do: Jason.decode!(body)

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))
  defp decoded(name), do: name |> fixture() |> Jason.decode!()
  defp message(reported), do: reported |> Map.fetch!("choices") |> hd() |> Map.fetch!("message")
  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  # Splits a fixture into fixed-size chunks so frames straddle chunk boundaries.
  defp chunks(name, size) do
    name |> fixture() |> chunk_binary(size)
  end

  defp chunk_binary(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_binary(binary, size) do
    [
      binary_part(binary, 0, size)
      | chunk_binary(binary_part(binary, size, byte_size(binary) - size), size)
    ]
  end

  defp last_usage(name) do
    name
    |> fixture()
    |> String.split("\n")
    |> Enum.flat_map(fn
      "data: {" <> _ = line -> [Jason.decode!(String.replace_prefix(line, "data: ", ""))]
      _ -> []
    end)
    |> Enum.find_value(& &1["usage"])
  end

  defp keepalive_frame do
    "data: " <>
      Jason.encode!(%{
        id: "chatcmpl-keepalive",
        object: "chat.completion.chunk",
        created: 0,
        model: "keepalive",
        choices: [%{index: 0, delta: %{role: "assistant", content: ""}, finish_reason: nil}]
      }) <> "\n\n"
  end
end
