defmodule Mojentic.LLM.SemanticRequestWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{CompletionConfig, Message, ToolCall}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}
  alias Mojentic.TestSupport.{CountingTool, ScriptedCompletionServer}

  @schema %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "string", "enum" => ["done"]}},
    "required" => ["value"],
    "additionalProperties" => false
  }
  @definition %{
    "type" => "function",
    "function" => %{
      "name" => "count",
      "description" => "count",
      "parameters" => %{"type" => "object"}
    }
  }
  @keys ~w(OPENAI_API_ENDPOINT OPENAI_API_KEY OLLAMA_HOST OMLX_HOST OMLX_API_KEY)

  setup do
    client = Application.fetch_env!(:mojentic, :http_client)
    saved = Map.new(@keys, &{&1, System.get_env(&1)})
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)
      for {key, value} <- saved do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  @tag :semantic_request_proof
  test "OpenAI events retries independently specified mixed tool history schema and controls" do
    exercise(OpenAI, :events, true)
  end

  defp exercise(gateway, operation, tracing) do
    server =
      start_supervised!({ScriptedCompletionServer,
        {self(), [http(503, "busy"), success(gateway, operation)]}})
    assert_receive {:server_port, port}
    configure(gateway, port)
    owner = self()
    policy = [
      max_attempts: 2,
      admission: fn _ -> :allow end,
      sleeper: fn _ -> :ok end,
      observer: &send(owner, {:semantic_lifecycle, &1})
    ]
    policy =
      if tracing do
        Keyword.put(policy, :trace_observer, fn event ->
          send(owner, {:semantic_trace, event})
          :ok
        end)
      else
        policy
      end
    config = CompletionConfig.new(
      temperature: 0.3, max_tokens: 27, num_ctx: 4192, num_predict: 31,
      top_p: 0.4, top_k: 8, reasoning_effort: :high,
      response_format: %{type: :json_object, schema: @schema}, recovery: policy)
    messages = history()
    tools = [%CountingTool{owner: self()}]
    result = invoke(gateway, operation, messages, tools, config)
    assert_success(result, operation)
    [first, second] = GenServer.call(server, :requests)
    assert first == second
    assert_payload(gateway, operation, payload(first))
    assert_trace(tracing, [first, second], drain(:semantic_trace), drain(:semantic_lifecycle))
    refute_received {:tool_executed, _}
  end

  defp history do
    call = %ToolCall{id: "prior-call-41", name: "count",
      arguments: %{"city" => "Montréal", "values" => [1, 3], "enabled" => false}}
    [
      Message.system("retain constraints"),
      Message.user("earlier question"),
      Message.assistant("earlier answer"),
      %Message{role: :assistant, content: "using tool", tool_calls: [call]},
      %Message{role: :tool, content: ~s({"count":2}), tool_calls: [call]},
      Message.user("finish")
    ]
  end

  defp expected_history(gateway) do
    arguments = %{"city" => "Montréal", "values" => [1, 3], "enabled" => false}
    call =
      if gateway == Ollama do
        %{"type" => "function", "function" => %{"name" => "count", "arguments" => arguments}}
      else
        %{"id" => "prior-call-41", "type" => "function",
          "function" => %{"name" => "count", "arguments" => Jason.encode!(arguments)}}
      end
    tool = %{"role" => "tool", "content" => ~s({"count":2})}
    tool =
      if gateway == Ollama do
        Map.put(tool, "tool_calls", [call])
      else
        Map.put(tool, "tool_call_id", "prior-call-41")
      end
    [
      %{"role" => "system", "content" => "retain constraints"},
      %{"role" => "user", "content" => "earlier question"},
      %{"role" => "assistant", "content" => "earlier answer"},
      %{"role" => "assistant", "content" => "using tool", "tool_calls" => [call]},
      tool,
      %{"role" => "user", "content" => "finish"}
    ]
  end

  defp assert_payload(gateway, operation, body) do
    assert body["model"] == "gpt-4o"
    assert body["messages"] == expected_history(gateway)
    assert Map.get(body, "stream", false) == (operation in [:events, :legacy])
    if operation in [:object, :events] do
      refute Map.has_key?(body, "tools")
    else
      assert body["tools"] == [@definition]
    end
    if gateway == Ollama do
      assert body["options"] == %{"temperature" => 0.3, "num_ctx" => 4192,
        "num_predict" => 31, "top_p" => 0.4, "top_k" => 8}
      assert body["format"] == @schema
      assert body["think"] == true
    else
      assert body["temperature"] == 0.3
      assert body["max_tokens"] == 27
      assert body["top_p"] == 0.4
      assert body["response_format"] == %{"type" => "json_schema",
        "json_schema" => %{"name" => "response", "schema" => @schema}}
      if gateway == OMLX do
        assert body["top_k"] == 8
        assert body["reasoning_effort"] == "high"
      else
        refute Map.has_key?(body, "top_k")
        refute Map.has_key?(body, "reasoning_effort")
      end
      refute Map.has_key?(body, "num_ctx")
      refute Map.has_key?(body, "num_predict")
    end
  end

  defp assert_trace(tracing, wires, traces, lifecycle) do
    starts = Enum.filter(lifecycle, &(&1.type == :attempt_started))
    assert Enum.map(starts, & &1.metadata.wire_attempt) == [1, 2]
    ids = Enum.map(starts, &Map.take(&1.metadata, [:logical_request_id, :attempt_id, :wire_attempt]))
    assert length(Enum.uniq(Enum.map(ids, & &1.attempt_id))) == 2
    assert length(Enum.uniq(Enum.map(ids, & &1.logical_request_id))) == 1
    for id <- ids do
      assert id.attempt_id =~ ~r/\A[0-9a-f-]{36}\z/
      assert id.logical_request_id =~ ~r/\A[0-9a-f-]{36}\z/
    end
    if tracing do
      requests = Enum.filter(traces, &(&1.type == :request))
      assert Enum.map(requests, & &1.ids) == ids
      for {trace, wire} <- Enum.zip(requests, wires) do
        [headers, body] = String.split(wire, "\r\n\r\n", parts: 2)
        assert trace.body == body
        for {key, value} <- trace.headers do
          assert String.downcase(headers) =~ String.downcase("#{key}: #{value}\r\n")
        end
      end
    else
      assert traces == []
    end
  end

  defp invoke(gateway, :events, messages, _tools, config),
    do: Enum.to_list(gateway.complete_stream_events("gpt-4o", messages, config))
  defp invoke(gateway, :legacy, messages, tools, config),
    do: Enum.to_list(gateway.complete_stream("gpt-4o", messages, tools, config))
  defp invoke(gateway, :object, messages, _tools, config),
    do: gateway.complete_object("gpt-4o", messages, @schema, config)
  defp invoke(gateway, :ordinary, messages, tools, config),
    do: gateway.complete("gpt-4o", messages, tools, config)

  defp assert_success(result, operation) when operation in [:events, :legacy] do
    refute Enum.any?(result, &match?({:error, _}, &1))
    assert Enum.any?(result, &match?({:content, _}, &1))
  end
  defp assert_success(result, :object), do: assert(result == {:ok, %{"value" => "done"}})
  defp assert_success(result, :ordinary), do: assert(match?({:ok, _}, result))

  defp success(gateway, operation) do
    content = ~s({"value":"done"})
    message = %{content: content}
    body =
      cond do
        gateway == Ollama -> Jason.encode!(%{message: message, done: true, done_reason: "stop"}) <> "\n"
        operation in [:events, :legacy] ->
          "data: " <> Jason.encode!(%{choices: [%{delta: message, finish_reason: "stop"}]}) <>
            "\n\ndata: [DONE]\n\n"
        true -> Jason.encode!(%{choices: [%{message: message, finish_reason: "stop"}]})
      end
    http(200, body)
  end
  defp http(status, body),
    do: "HTTP/1.1 #{status} Result\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
  defp payload(wire), do: wire |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()
  defp configure(gateway, port) do
    host = "http://127.0.0.1:#{port}"
    case gateway do
      OpenAI -> System.put_env("OPENAI_API_ENDPOINT", host <> "/v1")
      Ollama -> System.put_env("OLLAMA_HOST", host)
      OMLX -> System.put_env("OMLX_HOST", host)
    end
    System.put_env("OPENAI_API_KEY", "local-test-key")
    System.put_env("OMLX_API_KEY", "local-test-key")
  end
  defp drain(tag) do
    receive do
      {^tag, event} -> [event | drain(tag)]
    after
      0 -> []
    end
  end
end
