defmodule Mojentic.LLM.Gateways.OllamaStreamTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{Broker, CompletionConfig, Message}
  alias Mojentic.LLM.Gateways.{Ollama, OllamaStream}
  alias Mojentic.TestSupport.ChunkedHTTPServer
  alias Mojentic.Tracer.TracerEvents.{LLMCallTracerEvent, LLMResponseTracerEvent}

  @model "qwen3:32b"

  setup do
    previous = Application.get_env(:mojentic, :http_client)
    host = System.get_env("OLLAMA_HOST")
    timeout = System.get_env("OLLAMA_TIMEOUT")
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
    System.put_env("OLLAMA_TIMEOUT", "1000")

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, previous)
      restore("OLLAMA_HOST", host)
      restore("OLLAMA_TIMEOUT", timeout)
    end)

    :ok
  end

  describe "completion rules" do
    test "content then a done frame with done_reason stop completes with evidence" do
      wire = content("Hel") <> content("lo") <> done("stop", usage())

      assert [
               {:content, "Hel"},
               {:content, "lo"},
               {:completed, %{finish_reason: "stop", usage: usage, model: @model}}
             ] = parse([wire])

      assert usage == %{"prompt_eval_count" => 26, "eval_count" => 290}
    end

    test "a done frame split across chunks, without a trailing newline, still completes" do
      <<first::binary-size(7), rest::binary>> = content("ok") <> done("stop")
      assert [{:content, "ok"}, {:completed, _}] = parse([first, String.trim_trailing(rest)])
    end

    test "done frames without usage report unknown usage" do
      assert [{:completed, %{usage: nil}}] = parse([done("stop")])
    end

    test "any other done_reason is an incomplete completion carrying its evidence" do
      assert [
               {:content, "par"},
               {:error,
                {:incomplete_completion,
                 %{
                   finish_reason: "length",
                   usage: %{"prompt_eval_count" => 26, "eval_count" => 290},
                   model: @model
                 }}}
             ] = parse([content("par") <> done("length", usage())])

      assert [{:error, {:incomplete_completion, %{finish_reason: nil}}}] =
               parse([frame(%{done: true})])
    end

    test "end of stream without a done frame is an incomplete stream" do
      assert [{:content, "{}"}, {:error, :incomplete_stream}] = parse([content("{}")])
    end

    test "a native tool call is rejected" do
      call = %{function: %{name: "lookup", arguments: %{}}}

      assert [{:error, :unexpected_tool_calls}] =
               parse([frame(%{message: %{content: "", tool_calls: [call]}, done: false})])
    end

    test "a provider error frame is a provider error" do
      assert [{:content, "par"}, {:error, {:provider_error, "model crashed"}}] =
               parse([content("par") <> frame(%{error: "model crashed"})])
    end

    test "malformed frames are invalid stream events" do
      for wire <- ["not json\n", "[]\n", frame(%{message: %{content: "x"}})] do
        assert [{:error, :invalid_stream_event}] = parse([wire])
      end

      assert [{:error, :invalid_stream_content}] =
               parse([frame(%{message: %{content: 7}, done: false})])
    end

    test "nothing follows the terminal event" do
      assert [{:completed, _}] = parse([done("stop") <> content("late") <> "garbage\n"])
    end

    test "transport errors are terminal" do
      assert [{:content, "par"}, {:error, :timeout}] =
               Enum.to_list(
                 OllamaStream.events(fn ->
                   {:ok, [{:data, content("par")}, {:error, :timeout}, {:data, done("stop")}]}
                 end)
               )
    end
  end

  describe "over real chunked HTTP" do
    test "one POST streams content and proves completion" do
      serve([content("one"), content("two") <> done("stop", usage())])

      assert [{:content, "one"}, {:content, "two"}, {:completed, %{finish_reason: "stop"}}] =
               Enum.to_list(stream())

      assert_receive {:request, request}
      assert request =~ "POST /api/chat"
      body = ChunkedHTTPServer.request_body(request)
      assert body["stream"] == true
      assert body["model"] == @model
      refute Map.has_key?(body, "tools")
      refute_receive {:request, _}
    end

    test "the configured format is forwarded" do
      serve([done("stop")])
      schema = %{"type" => "object"}
      config = CompletionConfig.new(response_format: %{type: :json_object, schema: schema})
      assert [{:completed, _}] = Enum.to_list(stream(config))
      assert_receive {:request, request}
      assert ChunkedHTTPServer.request_body(request)["format"] == schema
    end

    test "halting after the first event cancels the request" do
      serve([content("partial")], true)
      assert [{:content, "partial"}] = Enum.take(stream(), 1)
      assert_receive {:cancel_result, {:error, :closed}}, 2000
    end

    test "cancelling the consumer process closes its request" do
      serve([content("partial")], true)
      owner = self()
      supervisor = start_supervised!(Task.Supervisor)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Enum.each(stream(), &send(owner, {:observed, &1}))
        end)

      assert_receive {:observed, {:content, "partial"}}, 2000
      Task.shutdown(task, :brutal_kill)
      assert_receive {:cancel_result, {:error, :closed}}, 2000
    end

    test "HTTP errors are observable and never retried" do
      serve([], false, 500)
      assert [{:error, {:http_error, 500}}] = Enum.to_list(stream())
      assert_receive {:request, _}
      refute_receive {:request, _}
    end

    test "the tracer records the call and the response with reported usage" do
      serve([content("four") <> done("stop", usage())])
      tracer = start_supervised!(Mojentic.Tracer.TracerSystem)
      broker = Broker.new(@model, Ollama, tracer: tracer)

      broker |> Broker.generate_stream_events([Message.user("2+2?")]) |> Stream.run()

      assert [%{model: @model}] =
               Mojentic.Tracer.get_events(tracer, event_type: LLMCallTracerEvent)

      assert [response] = Mojentic.Tracer.get_events(tracer, event_type: LLMResponseTracerEvent)
      assert response.content == "four"
      assert response.usage == %{"prompt_eval_count" => 26, "eval_count" => 290}
      assert response.provider_model == @model
      assert response.finish_reason == "stop"
    end
  end

  defp parse(chunks) do
    Enum.to_list(OllamaStream.events(fn -> {:ok, Enum.map(chunks, &{:data, &1})} end))
  end

  defp stream(config \\ CompletionConfig.new()) do
    Broker.generate_stream_events(Broker.new(@model, Ollama), [Message.user("hello")], config)
  end

  defp serve(chunks, hold \\ false, status \\ 200) do
    start_supervised!({ChunkedHTTPServer, {self(), chunks, hold, status}})
    assert_receive {:port, port}
    System.put_env("OLLAMA_HOST", "http://127.0.0.1:#{port}")
  end

  defp usage, do: %{prompt_eval_count: 26, eval_count: 290}

  defp content(text),
    do: frame(%{model: @model, message: %{role: "assistant", content: text}, done: false})

  defp done(reason, extra \\ %{}) do
    %{model: @model, message: %{role: "assistant", content: ""}, done: true, done_reason: reason}
    |> Map.merge(extra)
    |> frame()
  end

  defp frame(map), do: Jason.encode!(map) <> "\n"

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
