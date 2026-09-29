defmodule Mojentic.LLM.Gateways.OpenAI do
  @moduledoc """
  Gateway for OpenAI LLM service.

  This gateway provides access to OpenAI's API, supporting text generation,
  structured output, tool calling, streaming, and embeddings.

  ## Configuration

  Set environment variables to configure the gateway:

      export OPENAI_API_KEY=sk-...
      export OPENAI_API_ENDPOINT=https://api.openai.com/v1  # optional

  ## Examples

      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.OpenAI

      broker = Broker.new("gpt-4", OpenAI)
      messages = [Message.user("Hello!")]
      {:ok, response} = Broker.generate(broker, messages)

  """

  @behaviour Mojentic.LLM.Gateway

  alias Mojentic.LLM.Gateway
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Tools.Tool
  alias Mojentic.LLM.Gateways.OpenAILegacyStream
  alias Mojentic.LLM.Gateways.OpenAIMessagesAdapter
  alias Mojentic.LLM.Gateways.OpenAIModelRegistry

  require Logger

  @default_endpoint "https://api.openai.com/v1"
  @default_timeout 60_000

  defp http_client do
    Application.get_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
  end

  @impl Gateway
  def complete(model, messages, tools, config) do
    endpoint = get_endpoint()
    api_key = get_api_key()
    timeout = get_timeout()

    registry = OpenAIModelRegistry.new()
    openai_messages = OpenAIMessagesAdapter.adapt_messages(messages)
    adapted_params = adapt_parameters_for_model(registry, model, config)
    capabilities = OpenAIModelRegistry.get_model_capabilities(registry, model)

    body = %{
      model: model,
      messages: openai_messages
    }

    body = body |> Map.merge(adapted_params) |> put_response_format(config.response_format)

    # Add tools if provided and supported
    body =
      if tools && tools != [] && capabilities.supports_tools do
        tool_descriptors = Enum.map(tools, &Tool.descriptor/1)
        Map.put(body, :tools, tool_descriptors)
      else
        if tools && tools != [] do
          Logger.warning("Model #{model} does not support tools, ignoring tool configuration")
        end

        body
      end

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]

    case http_client().post(
           "#{endpoint}/chat/completions",
           Jason.encode!(body),
           headers,
           recv_timeout: timeout,
           timeout: timeout
         ) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_response(response_body)

      {:ok, %{status_code: status, body: error_body}} ->
        Logger.error("OpenAI API error: #{status} - #{error_body}")
        {:error, {:http_error, status, error_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl Gateway
  def complete_object(model, messages, schema, config) do
    endpoint = get_endpoint()
    api_key = get_api_key()
    timeout = get_timeout()

    registry = OpenAIModelRegistry.new()
    openai_messages = OpenAIMessagesAdapter.adapt_messages(messages)
    adapted_params = adapt_parameters_for_model(registry, model, config)

    body = %{
      model: model,
      messages: openai_messages,
      response_format: %{
        type: "json_schema",
        json_schema: %{
          name: "response",
          schema: schema
        }
      }
    }

    # Add adapted parameters
    body = Map.merge(body, adapted_params)

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]

    case http_client().post(
           "#{endpoint}/chat/completions",
           Jason.encode!(body),
           headers,
           recv_timeout: timeout,
           timeout: timeout
         ) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_object_response(response_body)

      {:ok, %{status_code: status, body: error_body}} ->
        Logger.error("OpenAI API error: #{status} - #{error_body}")
        {:error, {:http_error, status, error_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl Gateway
  def get_available_models do
    endpoint = get_endpoint()
    api_key = get_api_key()
    timeout = get_timeout()

    headers = [{"Authorization", "Bearer #{api_key}"}]

    case http_client().get("#{endpoint}/models", headers, recv_timeout: timeout, timeout: timeout) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => models}} ->
            names =
              models
              |> Enum.map(& &1["id"])
              |> Enum.sort()

            {:ok, names}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl Gateway
  def calculate_embeddings(text, model) do
    endpoint = get_endpoint()
    api_key = get_api_key()
    timeout = get_timeout()
    model = model || "text-embedding-3-large"

    # Chunk the text to handle token limits
    chunks = chunk_text(text, 8191)

    case process_embedding_chunks(chunks, model, endpoint, api_key, timeout) do
      {:ok, embeddings} ->
        {:ok, weighted_average_embeddings(embeddings)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Gateway
  def complete_stream(model, messages, tools, config) do
    registry = OpenAIModelRegistry.new()
    capabilities = OpenAIModelRegistry.get_model_capabilities(registry, model)

    # Check if streaming is supported
    unless capabilities.supports_streaming do
      raise "Model #{model} does not support streaming"
    end

    body = build_stream_request_body(model, messages, tools, config, registry, capabilities)
    headers = build_headers()
    timeout = get_timeout()

    OpenAILegacyStream.stream(fn -> initiate_stream_request(body, headers, timeout) end)
  end

  @impl Gateway
  def complete_stream_events(model, messages, config) do
    registry = OpenAIModelRegistry.new()
    capabilities = OpenAIModelRegistry.get_model_capabilities(registry, model)

    body =
      build_stream_request_body(model, messages, nil, config, registry, capabilities)
      |> Map.put(:stream_options, %{include_usage: true})

    client = http_client()

    Mojentic.LLM.Gateways.OpenAIStream.events(fn ->
      client.post_stream(
        "#{get_endpoint()}/chat/completions",
        Jason.encode!(body),
        build_headers(),
        recv_timeout: get_timeout(),
        timeout: get_timeout()
      )
    end)
  end

  defp build_stream_request_body(model, messages, tools, config, registry, capabilities) do
    openai_messages = OpenAIMessagesAdapter.adapt_messages(messages)
    adapted_params = adapt_parameters_for_model(registry, model, config)

    body = %{
      model: model,
      messages: openai_messages,
      stream: true
    }

    body = body |> Map.merge(adapted_params) |> put_response_format(config.response_format)

    if tools && tools != [] && capabilities.supports_tools do
      tool_descriptors = Enum.map(tools, &Tool.descriptor/1)
      Map.put(body, :tools, tool_descriptors)
    else
      body
    end
  end

  defp put_response_format(body, format) do
    case OpenAIMessagesAdapter.adapt_response_format(format) do
      nil -> body
      response_format -> Map.put(body, :response_format, response_format)
    end
  end

  defp build_headers do
    api_key = get_api_key()

    [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]
  end

  defp initiate_stream_request(body, headers, timeout) do
    endpoint = get_endpoint()

    http_client().post_stream(
      "#{endpoint}/chat/completions",
      Jason.encode!(body),
      headers,
      recv_timeout: timeout,
      timeout: timeout
    )
  end

  # Private functions

  defp get_endpoint do
    System.get_env("OPENAI_API_ENDPOINT") || @default_endpoint
  end

  defp get_api_key do
    System.get_env("OPENAI_API_KEY") || ""
  end

  defp get_timeout do
    case System.get_env("OPENAI_TIMEOUT") do
      nil ->
        @default_timeout

      timeout_str ->
        case Integer.parse(timeout_str) do
          {timeout, _} -> timeout
          :error -> @default_timeout
        end
    end
  end

  defp adapt_parameters_for_model(registry, model, config) do
    capabilities = OpenAIModelRegistry.get_model_capabilities(registry, model)

    params = %{}

    # Handle token limit parameter conversion
    max_tokens =
      cond do
        config.max_tokens > 0 -> config.max_tokens
        config.num_predict && config.num_predict > 0 -> config.num_predict
        true -> 16_384
      end

    params =
      case capabilities.model_type do
        :reasoning -> Map.put(params, :max_completion_tokens, max_tokens)
        _ -> Map.put(params, :max_tokens, max_tokens)
      end

    # Handle temperature restrictions
    params =
      cond do
        OpenAIModelRegistry.supports_temperature?(registry, model, config.temperature) ->
          Map.put(params, :temperature, config.temperature)

        capabilities.supported_temperatures == [] ->
          # Model doesn't support temperature at all
          Logger.warning("Model #{model} does not support temperature parameter at all")

          params

        true ->
          Logger.warning(
            "Model #{model} does not support temperature #{config.temperature}, using default 1.0"
          )

          Map.put(params, :temperature, 1.0)
      end

    # Add optional sampling parameters
    params =
      if config.top_p do
        Map.put(params, :top_p, config.top_p)
      else
        params
      end

    # Add reasoning_effort for reasoning models
    params =
      if config.reasoning_effort && capabilities.model_type == :reasoning do
        Map.put(params, :reasoning_effort, Atom.to_string(config.reasoning_effort))
      else
        if config.reasoning_effort && capabilities.model_type != :reasoning do
          Logger.warning(
            "Model #{model} is not a reasoning model, ignoring reasoning_effort parameter"
          )
        end

        params
      end

    params
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => message} = choice | _]} = response} ->
        content = Map.get(message, "content")

        tool_calls =
          case Map.get(message, "tool_calls") do
            nil -> []
            calls -> OpenAIMessagesAdapter.convert_tool_calls(calls)
          end

        {:ok,
         %GatewayResponse{
           content: content,
           tool_calls: tool_calls,
           model: response["model"],
           usage: response["usage"],
           finish_reason: choice["finish_reason"]
         }}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp parse_object_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} = choice | _]} = response} ->
        case Jason.decode(content) do
          {:ok, object} ->
            {:ok,
             %GatewayResponse{
               content: content,
               object: object,
               tool_calls: [],
               model: response["model"],
               usage: response["usage"],
               finish_reason: choice["finish_reason"]
             }}

          {:error, _} ->
            {:error, :invalid_json_object}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  defp chunk_text(text, _chunk_size) do
    # Simple implementation - for production, use proper tokenization
    # For now, just return the full text if it's not too long
    [text]
  end

  defp process_embedding_chunks(chunks, model, endpoint, api_key, timeout) do
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]

    results =
      Enum.map(chunks, fn chunk ->
        body = %{model: model, input: chunk}

        case http_client().post(
               "#{endpoint}/embeddings",
               Jason.encode!(body),
               headers,
               recv_timeout: timeout,
               timeout: timeout
             ) do
          {:ok, %{status_code: 200, body: response_body}} ->
            case Jason.decode(response_body) do
              {:ok, %{"data" => [%{"embedding" => embedding} | _]}} ->
                {:ok, embedding}

              _ ->
                {:error, :invalid_response}
            end

          {:ok, %{status_code: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, {:request_failed, reason}}
        end
      end)

    errors = Enum.filter(results, fn r -> match?({:error, _}, r) end)

    if errors != [] do
      List.first(errors)
    else
      embeddings = Enum.map(results, fn {:ok, emb} -> emb end)
      {:ok, embeddings}
    end
  end

  defp weighted_average_embeddings([embedding]) do
    # Single embedding - normalize and return
    normalize(embedding)
  end

  defp weighted_average_embeddings(embeddings) do
    # Calculate weights based on embedding lengths
    weights = Enum.map(embeddings, &length/1)
    total_weight = Enum.sum(weights)

    # Calculate weighted average
    dimension = length(List.first(embeddings))

    average =
      for dim_idx <- 0..(dimension - 1) do
        weighted_sum =
          Enum.zip(embeddings, weights)
          |> Enum.map(fn {emb, weight} ->
            Enum.at(emb, dim_idx, 0.0) * (weight / total_weight)
          end)
          |> Enum.sum()

        weighted_sum
      end

    normalize(average)
  end

  defp normalize(vector) do
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn x, acc -> acc + x * x end))

    if norm > 0.0 do
      Enum.map(vector, fn x -> x / norm end)
    else
      vector
    end
  end
end
