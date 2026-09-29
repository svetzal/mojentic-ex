defmodule Mojentic.LLM.Gateways.OMLX do
  @moduledoc """
  Gateway for [oMLX](https://github.com/jundot/omlx), an LLM server for Apple
  Silicon.

  oMLX speaks the OpenAI chat completions protocol. This gateway reuses the
  OpenAI message adapter and stream parsers, but it does not use the OpenAI
  model registry: every configured parameter goes to the server unchanged, for
  any model name.

  ## Configuration

  Set environment variables to configure the gateway:

      export OMLX_HOST=http://localhost:8000  # default; the gateway adds /v1
      export OMLX_API_KEY=...                 # optional; sent as a bearer token
      export OMLX_TIMEOUT=600000              # milliseconds (default)

  Without `OMLX_API_KEY`, requests carry no authorization header. The one
  timeout covers every request, including `load_model/1`. Its ten-minute
  default is longer than the other gateways use, because local models are
  slow: a 16384-token reply at 16 tokens a second takes about 17 minutes.

  ## Request parameters

  Chat requests send `model`, `messages`, `temperature` and `max_tokens`, and
  `top_p`, `top_k`, `reasoning_effort`, `response_format` and `tools` when they
  are set. `num_ctx` and `num_predict` are not sent: oMLX sets the context
  length per model.

  `reasoning_effort` goes to the model's chat template, so its effect depends
  on the model. When it is `nil`, the model's default applies, and Qwen 3
  models think by default. The model's reasoning arrives in
  `GatewayResponse.thinking`.

  ## Truncation

  When `max_tokens` ends generation during thinking, a non-streaming response
  puts the partial reasoning in `content`, `thinking` is `nil`, and
  `finish_reason` is `"length"`. The gateway maps the fields as the server
  sends them. `content` is not an answer unless `finish_reason` is `"stop"`.

  ## Structured output

  When oMLX cannot compile a grammar for a JSON response format, it falls back
  to prompt instructions and says so in a `Warning` response header. On a
  request that asked for JSON, the gateway puts that header's value in
  `GatewayResponse.metadata` under `"response_format_warning"` and logs a
  warning. It does not retry or fail. Validate the content yourself.

  ## Streaming

  Both streaming APIs drop oMLX keep-alive frames (frames whose `model` is
  `"keepalive"`) before parsing. `complete_stream_events/3` follows the
  OpenAI-compatible completion rules and yields no event for reasoning. The
  legacy `complete_stream/4` drops reasoning too, because it has no thinking
  chunk.

  ## Examples

      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.OMLX

      broker = Broker.new("Qwen3.8-27B-MLX-8bit", OMLX)
      {:ok, text} = Broker.generate(broker, [Message.user("Hello!")])

  """

  @behaviour Mojentic.LLM.Gateway

  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.Gateway
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Gateways.OpenAILegacyStream
  alias Mojentic.LLM.Gateways.OpenAIMessagesAdapter
  alias Mojentic.LLM.Gateways.OpenAIStream
  alias Mojentic.LLM.Tools.Tool

  require Logger

  @default_host "http://localhost:8000"
  @default_timeout 600_000
  @keepalive_model "keepalive"
  @warning_key "response_format_warning"

  @impl Gateway
  def complete(model, messages, tools, config) do
    body = chat_body(model, messages, tools, config)

    with {:ok, response} <- post_chat(body) do
      parse_completion(response, structured?(config))
    end
  end

  @impl Gateway
  def complete_object(model, messages, schema, config) do
    config = %{config | response_format: %{type: :json_object, schema: schema}}
    body = chat_body(model, messages, nil, config)

    with {:ok, response} <- post_chat(body),
         {:ok, completion} <- parse_completion(response, true) do
      parse_object(completion)
    end
  end

  @impl Gateway
  def get_available_models do
    case http_client().get(url("/models"), auth_headers(), timeout_opts(get_timeout())) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => models}} when is_list(models) ->
            {:ok, models |> Enum.map(& &1["id"]) |> Enum.sort()}

          _ ->
            {:error, :invalid_response}
        end

      other ->
        failure(other)
    end
  end

  @doc """
  Calculates an embedding with one request to `/v1/embeddings`.

  The model is required: oMLX has no standard embedding model. A `nil` or
  empty model raises `ArgumentError` before any request. The text is sent
  whole, with no client-side chunking. Using a chat model is a provider error.
  """
  @impl Gateway
  def calculate_embeddings(_text, model) when model in [nil, ""] do
    raise ArgumentError, "oMLX embeddings require a model; there is no default embedding model"
  end

  def calculate_embeddings(text, model) do
    body = Jason.encode!(%{model: model, input: text})

    case http_client().post(url("/embeddings"), body, json_headers(), timeout_opts(get_timeout())) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"data" => [%{"embedding" => embedding} | _]}} -> {:ok, embedding}
          _ -> {:error, :invalid_response}
        end

      other ->
        failure(other)
    end
  end

  @impl Gateway
  def complete_stream(model, messages, tools, config) do
    body = model |> chat_body(messages, tools, config) |> Map.put(:stream, true)

    OpenAILegacyStream.stream(fn -> post_chat_stream(body) end)
  end

  @doc """
  Streams one non-executing turn as content and terminal events.

  Follows the OpenAI-compatible completion rules: success requires a
  `finish_reason` of `"stop"` and the `data: [DONE]` marker. Keep-alive frames
  are dropped before parsing, so they never report `"keepalive"` as the
  provider model. Reasoning deltas yield no events. Use it through
  `Mojentic.LLM.Broker.generate_stream_events/3`.
  """
  @impl Gateway
  def complete_stream_events(model, messages, config) do
    body =
      model
      |> chat_body(messages, nil, config)
      |> Map.merge(%{stream: true, stream_options: %{include_usage: true}})

    OpenAIStream.events(fn -> post_chat_stream(body) end)
  end

  @doc """
  Loads a model into memory ahead of its first request.

  Blocks until the model is loaded, within the `OMLX_TIMEOUT` timeout.
  A chat request loads its model automatically; this is for warming up.
  Returns `:ok`, or `{:error, reason}` as the other requests do.
  """
  @spec load_model(String.t()) :: :ok | Gateway.error()
  def load_model(model), do: post_model_action(model, "load")

  @doc """
  Unloads a model from memory.

  Unloading a model that is not loaded is a provider error
  (`{:error, {:http_error, 400, body}}`).
  """
  @spec unload_model(String.t()) :: :ok | Gateway.error()
  def unload_model(model), do: post_model_action(model, "unload")

  # Request building

  defp chat_body(model, messages, tools, config) do
    %{
      model: model,
      messages: OpenAIMessagesAdapter.adapt_messages(messages),
      temperature: config.temperature
    }
    |> put_set(:max_tokens, config.max_tokens)
    |> put_set(:top_p, config.top_p)
    |> put_set(:top_k, config.top_k)
    |> put_set(:reasoning_effort, config.reasoning_effort && to_string(config.reasoning_effort))
    |> put_set(
      :response_format,
      OpenAIMessagesAdapter.adapt_response_format(config.response_format)
    )
    |> put_tools(tools)
  end

  defp put_set(body, _key, nil), do: body
  defp put_set(body, key, value), do: Map.put(body, key, value)

  defp put_tools(body, tools) when tools in [nil, []], do: body
  defp put_tools(body, tools), do: Map.put(body, :tools, Enum.map(tools, &Tool.descriptor/1))

  defp structured?(%CompletionConfig{response_format: %{type: :json_object}}), do: true
  defp structured?(_config), do: false

  # Transport

  defp post_chat(body) do
    case http_client().post(
           url("/chat/completions"),
           Jason.encode!(body),
           json_headers(),
           timeout_opts(get_timeout())
         ) do
      {:ok, %{status_code: 200} = response} -> {:ok, response}
      other -> failure(other)
    end
  end

  defp post_chat_stream(body) do
    with {:ok, frames} <-
           http_client().post_stream(
             url("/chat/completions"),
             Jason.encode!(body),
             json_headers(),
             timeout_opts(get_timeout())
           ) do
      {:ok, drop_keepalive_frames(frames)}
    end
  end

  defp post_model_action(model, action) do
    path = "/models/#{URI.encode(model, &URI.char_unreserved?/1)}/#{action}"

    case http_client().post(url(path), "", auth_headers(), timeout_opts(get_timeout())) do
      {:ok, %{status_code: 200}} -> :ok
      other -> failure(other)
    end
  end

  defp failure({:ok, %{status_code: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp failure({:error, reason}), do: {:error, {:request_failed, reason}}

  # Response parsing

  defp parse_completion(%{body: body} = response, structured?) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => message} = choice | _]} = reported} ->
        {:ok,
         %GatewayResponse{
           content: message["content"],
           thinking: message["reasoning_content"],
           tool_calls: OpenAIMessagesAdapter.convert_tool_calls(message["tool_calls"] || []),
           model: reported["model"],
           usage: reported["usage"],
           finish_reason: choice["finish_reason"],
           metadata: format_warning_metadata(response, structured?)
         }}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp parse_object(%GatewayResponse{content: content} = completion) do
    case Jason.decode(content || "") do
      {:ok, object} -> {:ok, %{completion | object: object}}
      {:error, _} -> {:error, :invalid_json_object}
    end
  end

  # oMLX reports an unenforced response format in a `Warning` header. It is
  # evidence about a structured request, not a failure.
  defp format_warning_metadata(_response, false), do: %{}

  defp format_warning_metadata(response, true) do
    case response_header(response, "warning") do
      nil ->
        %{}

      warning ->
        Logger.warning("oMLX did not enforce the requested response format: #{warning}")
        %{@warning_key => warning}
    end
  end

  defp response_header(response, name) do
    values =
      for {key, value} <- Map.get(response, :headers, []),
          String.downcase(key) == name,
          do: value

    if values == [], do: nil, else: Enum.join(values, ", ")
  end

  # Keep-alive frames

  # oMLX opens every chat stream, and pads long prefill, with `data:` frames
  # whose model is "keepalive". They carry no content, but a parser would take
  # "keepalive" as the provider model. Drop them line by line, carrying a
  # partial line across chunks, before the OpenAI-compatible parsers see them.
  defp drop_keepalive_frames(frames) do
    Stream.transform(
      frames,
      fn -> "" end,
      fn
        {:data, chunk}, partial ->
          {lines, [rest]} = (partial <> chunk) |> String.split("\n") |> Enum.split(-1)
          {data_element(Enum.reject(lines, &keepalive_line?/1)), rest}

        other, partial ->
          {[other], partial}
      end,
      fn
        "" -> {[], ""}
        partial -> {[{:data, partial}], ""}
      end,
      fn _partial -> :ok end
    )
  end

  defp data_element([]), do: []
  defp data_element(lines), do: [{:data, Enum.map_join(lines, &(&1 <> "\n"))}]

  defp keepalive_line?("data:" <> data) do
    String.contains?(data, @keepalive_model) and
      match?({:ok, %{"model" => @keepalive_model}}, Jason.decode(data))
  end

  defp keepalive_line?(_line), do: false

  # Configuration

  defp http_client do
    Application.get_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
  end

  defp url(path), do: get_host() <> "/v1" <> path

  defp get_host do
    (System.get_env("OMLX_HOST") || @default_host) |> String.trim_trailing("/")
  end

  defp auth_headers do
    case System.get_env("OMLX_API_KEY") do
      key when key in [nil, ""] -> []
      key -> [{"Authorization", "Bearer #{key}"}]
    end
  end

  defp json_headers, do: [{"Content-Type", "application/json"} | auth_headers()]

  defp get_timeout do
    with value when is_binary(value) <- System.get_env("OMLX_TIMEOUT"),
         {timeout, _} <- Integer.parse(value) do
      timeout
    else
      _ -> @default_timeout
    end
  end

  defp timeout_opts(timeout), do: [recv_timeout: timeout, timeout: timeout]
end
