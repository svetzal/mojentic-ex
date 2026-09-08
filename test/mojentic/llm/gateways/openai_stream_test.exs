defmodule Mojentic.LLM.Gateways.OpenAIStreamTest do
  use ExUnit.Case, async: false
  alias Mojentic.LLM.{Broker, CompletionConfig, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, OpenAIStream}

  defmodule Server do
    use GenServer
    def start_link(options), do: GenServer.start_link(__MODULE__, options)

    def init({owner, chunks, hold, status}) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_, port}} = :inet.sockname(listener)
      send(owner, {:port, port})
      {:ok, {owner, listener, chunks, hold, status}, {:continue, :serve}}
    end

    def handle_continue(:serve, {owner, listener, chunks, hold, status} = state) do
      {:ok, socket} = :gen_tcp.accept(listener, 2000)
      :gen_tcp.close(listener)
      {:ok, request} = :gen_tcp.recv(socket, 0, 2000)
      send(owner, {:request, request})

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Result\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
        )

      for chunk <- chunks do
        :ok =
          :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
      end

      if hold do
        send(owner, {:cancel_result, :gen_tcp.recv(socket, 0, 2000)})
      else
        :gen_tcp.send(socket, "0\r\n\r\n")
      end

      :gen_tcp.close(socket)
      {:noreply, state}
    end
  end

  setup do
    previous = Application.get_env(:mojentic, :http_client)
    endpoint = System.get_env("OPENAI_API_ENDPOINT")
    timeout = System.get_env("OPENAI_TIMEOUT")
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
    System.put_env("OPENAI_TIMEOUT", "1000")

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, previous)
      restore("OPENAI_API_ENDPOINT", endpoint)
      restore("OPENAI_TIMEOUT", timeout)
    end)

    :ok
  end

  test "real chunked HTTP makes one POST and proves completion with usage" do
    wire =
      event("{\"content\":") <>
        event(~s("ok","tool_calls":[]})) <>
        finish("stop") <>
        ~s(data: {"choices":[],"usage":{"total_tokens":12}}\n\n) <> "data: [DONE]\n\n"

    <<first::binary-size(19), rest::binary>> = wire
    serve([first, rest])
    events = Enum.to_list(stream())

    assert [
             {:content, _},
             {:content, _},
             {:completed, %{finish_reason: "stop", usage: %{"total_tokens" => 12}}}
           ] = events

    assert_receive {:request, request}
    assert request =~ "POST /chat/completions"
    assert request =~ "\"stream\":true"
    assert request =~ "\"include_usage\":true"
    refute request =~ "\"tools\":"
    refute_receive {:request, _}
  end

  test "single-turn streaming forwards requested JSON mode in the real HTTP body" do
    serve([event("{}"), finish("stop"), "data: [DONE]\n\n"])
    config = CompletionConfig.new(response_format: %{type: :json_object})

    assert [{:content, "{}"}, {:completed, _}] =
             Enum.to_list(
               Broker.generate_stream_events(
                 Broker.new("gpt-4o", OpenAI),
                 [Message.user("JSON")],
                 config
               )
             )

    assert_receive {:request, request}
    body = request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()
    assert body["response_format"] == %{"type" => "json_object"}
    refute Map.has_key?(body, "tools")
  end

  test "legacy streaming forwards an explicit JSON schema without executing tools" do
    serve([event("{}"), finish("stop"), "data: [DONE]\n\n"])
    schema = %{"type" => "object", "properties" => %{}}
    config = CompletionConfig.new(response_format: %{type: :json_object, schema: schema})

    assert ["{}"] =
             Enum.to_list(
               Broker.generate_stream(
                 Broker.new("gpt-4o", OpenAI),
                 [Message.user("JSON")],
                 nil,
                 config
               )
             )

    assert_receive {:request, request}
    body = request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()

    assert body["response_format"] == %{
             "type" => "json_schema",
             "json_schema" => %{"name" => "response", "schema" => schema}
           }

    refute Map.has_key?(body, "tools")
  end

  test "complete-looking JSON followed by EOF remains failed and retains content" do
    serve([event("{}")])
    assert [{:content, "{}"}, {:error, :incomplete_stream}] = Enum.to_list(stream())
  end

  test "halting after first chunk cancels real HTTP response" do
    serve([event("partial")], true)
    assert [{:content, "partial"}] = Enum.take(stream(), 1)
    assert_receive {:cancel_result, {:error, :closed}}, 2000
  end

  test "cancelling the consumer process closes its real HTTP request" do
    serve([event("partial")], true)
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

  test "HTTP errors are observable and are never retried" do
    serve([], false, 504)
    assert [{:error, {:http_error, 504}}] = Enum.to_list(stream())
    assert_receive {:request, _}
    refute_receive {:request, _}
  end

  test "absolute transport deadline preserves partial response then cancels" do
    System.put_env("OPENAI_TIMEOUT", "50")
    serve([event("partial")], true)
    assert [{:content, "partial"}, {:error, :timeout}] = Enum.to_list(stream())
    assert_receive {:cancel_result, {:error, :closed}}, 2000
  end

  test "missing finish proof, length exhaustion, malformed SSE and native tools fail closed" do
    for {wire, reason} <- [
          {"data: [DONE]\n\n",
           {:incomplete_completion, %{finish_reason: nil, usage: nil, model: nil}}},
          {finish("length") <> "data: [DONE]\n\n",
           {:incomplete_completion, %{finish_reason: "length", usage: nil, model: nil}}},
          {"data: invalid\n\n", :invalid_stream_event},
          {"data: {\"error\":{\"code\":\"timeout\"}}\n\n",
           {:provider_error, %{"code" => "timeout"}}},
          {"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{}]}}]}\n\n", :unexpected_tool_calls}
        ] do
      assert [{:error, ^reason}] =
               Enum.to_list(OpenAIStream.events(fn -> {:ok, [{:data, wire}]} end))
    end
  end

  test "legacy string broker stream consumes the real HTTP stream once" do
    serve([event("one"), event("two"), finish("stop"), "data: [DONE]\n\n"])

    assert ["one", "two"] =
             Enum.to_list(
               Broker.generate_stream(Broker.new("gpt-4o", OpenAI), [Message.user("hello")])
             )
  end

  defp stream do
    Broker.generate_stream_events(
      Broker.new("gpt-4o", OpenAI),
      [Message.user("hello")],
      CompletionConfig.new(max_tool_iterations: 0)
    )
  end

  defp serve(chunks, hold \\ false, status \\ 200) do
    start_supervised!({Server, {self(), chunks, hold, status}})
    assert_receive {:port, port}
    System.put_env("OPENAI_API_ENDPOINT", "http://127.0.0.1:#{port}")
  end

  defp event(content),
    do:
      "data: " <>
        Jason.encode!(%{choices: [%{delta: %{content: content}, finish_reason: nil}]}) <> "\n\n"

  defp finish(reason),
    do: "data: " <> Jason.encode!(%{choices: [%{delta: %{}, finish_reason: reason}]}) <> "\n\n"

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end
