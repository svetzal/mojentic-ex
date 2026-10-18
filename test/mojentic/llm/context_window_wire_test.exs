defmodule Mojentic.LLM.ContextWindowWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{CompletionConfig, Gateway, Message}
  alias Mojentic.LLM.Gateways.{Ollama, OMLX, OpenAI}
  alias Mojentic.TestSupport.{ContextWindowContract, ScriptedTransport}

  @external_resource "test/contracts/context_window_v1.json"
  @contract ContextWindowContract.contract()
  @external_resource "test/contracts/request_fidelity_v1.json"
  @fidelity Jason.decode!(File.read!("test/contracts/request_fidelity_v1.json"))
  @keys ["OLLAMA_HOST", "OMLX_HOST", "OMLX_API_KEY", "OPENAI_API_ENDPOINT", "OPENAI_API_KEY"]

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

  for boundary <- [:adapter, :consumer], row <- @contract["cases"] do
    @boundary boundary
    @row row
    if row["name"] == "reject-json-string-object", do: @tag(:context_string_proof)

    test "context-window-v1 #{boundary} #{row["provider"]} #{row["name"]} exact wire and result" do
      gateway = gateway(@row["provider"])
      server = server(gateway, [ContextWindowContract.response(@row)])

      if @row["without_api_key"], do: System.delete_env("OMLX_API_KEY")

      result =
        case @boundary do
          :adapter -> gateway.get_model_context_window(@row["model"])
          :consumer -> Gateway.get_model_context_window(gateway, @row["model"])
        end

      [request] = GenServer.call(server, :requests)
      assert_discovery_request(request, @row)
      assert result == ContextWindowContract.result(@row)
    end
  end

  for row <- @contract["registry_cases"] do
    @row row
    test "context-window-v1 registry #{@row["model"]} performs no HTTP" do
      # An HTTP Mox gateway with no expectations rejects any unexpected I/O.
      Application.put_env(:mojentic, :http_client, Mojentic.HTTPMock)
      expected = {:ok, ContextWindowContract.window(@row["window"])}
      assert OpenAI.get_model_context_window(@row["model"]) == expected
      assert Gateway.get_model_context_window(OpenAI, @row["model"]) == expected
    end
  end

  for gateway <- [Ollama, OMLX], boundary <- [:adapter, :consumer] do
    @gateway gateway
    @boundary boundary
    test "context-window-v1 #{@gateway} #{@boundary} transport failure retains cause" do
      transport = server(@gateway, List.duplicate("", if(@gateway == OMLX, do: 4, else: 1)))

      result =
        case @boundary do
          :adapter -> @gateway.get_model_context_window("exact-model")
          :consumer -> Gateway.get_model_context_window(@gateway, "exact-model")
        end

      assert {:error, {:request_failed, %Req.TransportError{reason: :closed}}} = result
      assert_receive {:transport_request, request}
      row = Enum.find(@contract["cases"], &(&1["provider"] == provider(@gateway)))
      assert_discovery_request(request, row)
      expected_attempts = if @gateway == OMLX, do: 4, else: 1
      assert GenServer.call(transport, :requests) == List.duplicate(request, expected_attempts)
    end
  end

  for gateway <- [Ollama, OMLX, OpenAI], operation <- [:complete, :object, :legacy, :events] do
    @gateway gateway
    @operation operation
    test "context-window-v1 #{@gateway} discovery leaves subsequent #{@operation} request unchanged" do
      row = Enum.find(@contract["cases"], &(&1["provider"] == provider(@gateway)))

      body =
        @fidelity["responses"][response_provider(@gateway) <> "-" <> Atom.to_string(@operation)]

      response = ContextWindowContract.http(200, body)

      responses =
        if @gateway == OpenAI,
          do: [response, response],
          else: [response, ContextWindowContract.response(row), response]

      server = server(@gateway, responses)
      config = CompletionConfig.new(temperature: 0, max_tokens: 73)
      before = complete(@gateway, @operation, config)
      assert {:ok, _} = Gateway.get_model_context_window(@gateway, "exact-model")
      assert complete(@gateway, @operation, config) == before
      requests = GenServer.call(server, :requests)
      assert List.first(requests) == List.last(requests)
      [headers, encoded] = String.split(List.last(requests), "\r\n\r\n", parts: 2)
      path = if @gateway == Ollama, do: "/api/chat", else: "/v1/chat/completions"
      assert headers =~ "POST #{path} HTTP/1.1"
      assert Jason.decode!(encoded) == completion_body(@gateway, @operation)
      assert config == CompletionConfig.new(temperature: 0, max_tokens: 73)
    end
  end

  for row <- @contract["lookup_cases"] do
    @row row
    test "context-window-v1 #{@row["provider"]} preserves configured model lookup before and after discovery" do
      gateway = gateway(@row["provider"])
      response = ContextWindowContract.http(200, Jason.encode!(@row["response"]))
      discovery = Enum.find(@contract["cases"], &(&1["provider"] == provider(gateway)))

      responses =
        if gateway == OpenAI,
          do: [response, response],
          else: [response, ContextWindowContract.response(discovery), response]

      server = server(gateway, responses)
      assert gateway.get_available_models() == {:ok, @row["names"]}
      assert {:ok, _} = Gateway.get_model_context_window(gateway, "exact-model")
      assert gateway.get_available_models() == {:ok, @row["names"]}
      requests = GenServer.call(server, :requests)
      assert List.first(requests) == List.last(requests)
      [headers, body] = String.split(List.last(requests), "\r\n\r\n", parts: 2)
      assert headers =~ "GET #{@row["path"]} HTTP/1.1"
      assert body == ""

      if gateway != Ollama,
        do: assert(String.downcase(headers) =~ "authorization: bearer contract-key")
    end
  end

  @tag :context_proof
  test "Ollama discovery separates advertised and effective windows through production Req" do
    client = Application.fetch_env!(:mojentic, :http_client)
    host = System.get_env("OLLAMA_HOST")
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)
      if host, do: System.put_env("OLLAMA_HOST", host), else: System.delete_env("OLLAMA_HOST")
    end)

    body =
      Jason.encode!(%{
        "model_info" => %{"qwen4_exp.context_length" => 262_144},
        "parameters" => "temperature 0.6\nnum_ctx 32768\n"
      })

    response =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
        body

    server = start_supervised!({ScriptedTransport, {self(), [response]}})
    assert_receive {:transport_id, port}
    System.put_env("OLLAMA_HOST", "http://127.0.0.1:#{port}")
    assert {:ok, window} = Ollama.get_model_context_window("exact-model")

    assert window == %{
             max_context_tokens: 262_144,
             field: "model_info.qwen4_exp.context_length",
             model_num_ctx: 32_768
           }

    assert Ollama.effective_context_window(window, CompletionConfig.new()) == 32_768

    assert Ollama.effective_context_window(window, CompletionConfig.new(num_ctx: 524_288)) ==
             262_144

    [request] = GenServer.call(server, :requests)
    [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    assert headers =~ "POST /api/show HTTP/1.1"
    assert String.downcase(headers) =~ "content-type: application/json"
    assert Jason.decode!(body) == %{"model" => "exact-model"}
  end

  defp gateway("ollama"), do: Ollama
  defp gateway("omlx"), do: OMLX
  defp gateway("openai"), do: OpenAI
  defp provider(Ollama), do: "ollama"
  defp provider(_), do: "omlx"
  defp response_provider(Ollama), do: "ollama"
  defp response_provider(_), do: "openai"

  defp server(gateway, responses) do
    server = start_supervised!({ScriptedTransport, {self(), responses}})
    assert_receive {:transport_id, port}
    endpoint = "http://127.0.0.1:#{port}"

    case gateway do
      Ollama ->
        System.put_env("OLLAMA_HOST", endpoint)

      OMLX ->
        System.put_env("OMLX_HOST", endpoint <> "/")
        System.put_env("OMLX_API_KEY", "contract-key")

      OpenAI ->
        System.put_env("OPENAI_API_ENDPOINT", endpoint <> "/v1")
        System.put_env("OPENAI_API_KEY", "contract-key")
    end

    server
  end

  defp assert_discovery_request(request, row) do
    [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(String.downcase(headers), "\r\n")

    assert request_line ==
             String.downcase(
               row["request"]["method"] <> " " <> row["request"]["path"] <> " HTTP/1.1"
             )

    if row["provider"] == "omlx" do
      if row["without_api_key"],
        do: refute(Enum.any?(header_lines, &String.starts_with?(&1, "authorization:"))),
        else: assert("authorization: bearer contract-key" in header_lines)

      assert body == ""
    else
      refute Enum.any?(header_lines, &String.starts_with?(&1, "authorization:"))
      assert "content-type: application/json" in header_lines
      assert Jason.decode!(body) == row["request"]["body"]
    end
  end

  defp complete(gateway, :complete, config),
    do: gateway.complete("exact-model", [Message.user("question")], nil, config)

  defp complete(gateway, :object, config),
    do:
      gateway.complete_object(
        "exact-model",
        [Message.user("question")],
        %{"type" => "object"},
        config
      )

  defp complete(gateway, :legacy, config),
    do:
      gateway.complete_stream("exact-model", [Message.user("question")], nil, config)
      |> Enum.take(1)

  defp complete(gateway, :events, config) do
    gateway.complete_stream_events("exact-model", [Message.user("question")], config)
    |> Enum.map(fn
      {:completed, evidence} -> {:completed, Map.drop(evidence, [:elapsed_ms, :metadata])}
      event -> event
    end)
  end

  defp completion_body(gateway, operation) do
    body = %{
      "model" => "exact-model",
      "messages" => [%{"role" => "user", "content" => "question"}]
    }

    body =
      if gateway == Ollama,
        do:
          Map.merge(body, %{
            "options" => %{"temperature" => 0, "num_predict" => 73},
            "stream" => operation in [:legacy, :events]
          }),
        else: Map.merge(body, %{"temperature" => 0, "max_tokens" => 73})

    body =
      if gateway != Ollama and operation in [:legacy, :events],
        do: Map.put(body, "stream", true),
        else: body

    body =
      if gateway != Ollama and operation == :events,
        do: Map.put(body, "stream_options", %{"include_usage" => true}),
        else: body

    case {gateway, operation} do
      {Ollama, :object} ->
        Map.put(body, "format", %{"type" => "object"})

      {_, :object} ->
        Map.put(body, "response_format", %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "response",
            "schema" => %{"type" => "object"}
          }
        })

      _ ->
        body
    end
  end
end
