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
  alias Mojentic.LLM.ToolCall
  alias Mojentic.LLM.Tools.Tool
  alias Mojentic.LLM.Gateways.OpenAIMessagesAdapter
  alias Mojentic.LLM.Gateways.OpenAIModelRegistry

  require Logger

  @default_endpoint "https://api.openai.com/v1"
  @default_timeout 60_000

  defp http_client do
    Application.get_env(:mojentic, :http_client, HTTPoison)
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

    # Add adapted parameters
    body = Map.merge(body, adapted_params)

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

    Stream.resource(
      fn -> initiate_stream_request(body, headers, timeout) end,
      fn state -> process_stream_chunk(state, timeout) end,
      fn state -> cleanup_stream(state) end
    )
  end

  defp build_stream_request_body(model, messages, tools, config, registry, capabilities) do
    openai_messages = OpenAIMessagesAdapter.adapt_messages(messages)
    adapted_params = adapt_parameters_for_model(registry, model, config)

    body = %{
      model: model,
      messages: openai_messages,
      stream: true
    }

    body = Map.merge(body, adapted_params)

    if tools && tools != [] && capabilities.supports_tools do
      tool_descriptors = Enum.map(tools, &Tool.descriptor/1)
      Map.put(body, :tools, tool_descriptors)
    else
      body
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

    case http_client().post(
           "#{endpoint}/chat/completions",
           Jason.encode!(body),
           headers,
           recv_timeout: timeout,
           timeout: timeout,
           stream_to: self(),
           async: :once
         ) do
      {:ok, %HTTPoison.AsyncResponse{id: id}} ->
        {id, "", %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_stream_chunk(:halt, _timeout), do: {:halt, :halt}
  defp process_stream_chunk({:error, _reason} = error, _timeout), do: {[error], :halt}

  defp process_stream_chunk({id, buffer, tool_calls_acc}, timeout) do
    receive do
      %HTTPoison.AsyncStatus{id: ^id} ->
        http_client().stream_next(%HTTPoison.AsyncResponse{id: id})
        {[], {id, buffer, tool_calls_acc}}

      %HTTPoison.AsyncHeaders{id: ^id} ->
        http_client().stream_next(%HTTPoison.AsyncResponse{id: id})
        {[], {id, buffer, tool_calls_acc}}

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        http_client().stream_next(%HTTPoison.AsyncResponse{id: id})
        parse_sse_chunks(chunk, buffer, tool_calls_acc, id)

      %HTTPoison.AsyncEnd{id: ^id} ->
        handle_stream_end(tool_calls_acc)
    after
      timeout ->
        {[{:error, :timeout}], :halt}
    end
  end

  defp handle_stream_end(tool_calls_acc) do
    result =
      if map_size(tool_calls_acc) > 0 do
        [{:tool_calls, build_complete_tool_calls(tool_calls_acc)}]
      else
        []
      end

    {result, :halt}
  end

  defp cleanup_stream(:halt), do: :ok
  defp cleanup_stream({:error, _}), do: :ok
  defp cleanup_stream(_), do: :ok

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

    params
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => message} | _]}} ->
        content = Map.get(message, "content")

        tool_calls =
          case Map.get(message, "tool_calls") do
            nil -> []
            calls -> OpenAIMessagesAdapter.convert_tool_calls(calls)
          end

        {:ok,
         %GatewayResponse{
           content: content,
           tool_calls: tool_calls
         }}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp parse_object_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        case Jason.decode(content) do
          {:ok, object} ->
            {:ok,
             %GatewayResponse{
               content: content,
               object: object,
               tool_calls: []
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

  # Parse SSE chunks from OpenAI streaming response
  defp parse_sse_chunks(chunk, buffer, tool_calls_acc, id) do
    new_buffer = buffer <> chunk

    # Split on double newlines (SSE format)
    lines = String.split(new_buffer, "\n", trim: false)

    # Process complete lines
    {complete_lines, remaining_buffer} =
      if String.ends_with?(new_buffer, "\n") do
        {Enum.filter(lines, &(&1 != "")), ""}
      else
        case Enum.split(lines, -1) do
          {complete, [incomplete]} -> {Enum.filter(complete, &(&1 != "")), incomplete}
          {complete, []} -> {Enum.filter(complete, &(&1 != "")), ""}
        end
      end

    # Process each complete line
    {results, new_tool_calls_acc} =
      Enum.reduce(complete_lines, {[], tool_calls_acc}, fn line, {acc_results, acc_tools} ->
        if String.starts_with?(line, "data: ") do
          data = String.replace_prefix(line, "data: ", "")

          if data == "[DONE]" do
            # Final chunk - return accumulated tool calls if any
            if map_size(acc_tools) > 0 do
              {[{:tool_calls, build_complete_tool_calls(acc_tools)} | acc_results], %{}}
            else
              {acc_results, acc_tools}
            end
          else
            case Jason.decode(data) do
              {:ok, json} ->
                parse_streaming_json(json, acc_results, acc_tools)

              {:error, _} ->
                Logger.warning("Failed to parse SSE chunk: #{data}")
                {acc_results, acc_tools}
            end
          end
        else
          {acc_results, acc_tools}
        end
      end)

    {Enum.reverse(results), {id, remaining_buffer, new_tool_calls_acc}}
  end

  defp parse_streaming_json(json, acc_results, acc_tools) do
    case json do
      %{"choices" => [%{"delta" => delta, "finish_reason" => finish_reason} | _]} ->
        # Handle content
        acc_results =
          case Map.get(delta, "content") do
            nil -> acc_results
            "" -> acc_results
            content -> [{:content, content} | acc_results]
          end

        # Accumulate tool calls
        acc_tools =
          case Map.get(delta, "tool_calls") do
            nil ->
              acc_tools

            tool_calls ->
              Enum.reduce(tool_calls, acc_tools, fn tc, tools ->
                index = tc["index"]

                current =
                  Map.get(tools, index, %{
                    id: nil,
                    name: nil,
                    arguments: ""
                  })

                current =
                  if tc["id"] do
                    Map.put(current, :id, tc["id"])
                  else
                    current
                  end

                current =
                  case get_in(tc, ["function", "name"]) do
                    nil -> current
                    name -> Map.put(current, :name, name)
                  end

                current =
                  case get_in(tc, ["function", "arguments"]) do
                    nil -> current
                    args -> Map.put(current, :arguments, current.arguments <> args)
                  end

                Map.put(tools, index, current)
              end)
          end

        # Check if we need to emit tool calls
        if finish_reason == "tool_calls" && map_size(acc_tools) > 0 do
          {[{:tool_calls, build_complete_tool_calls(acc_tools)} | acc_results], %{}}
        else
          {acc_results, acc_tools}
        end

      _ ->
        {acc_results, acc_tools}
    end
  end

  defp build_complete_tool_calls(tool_calls_acc) do
    tool_calls_acc
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, tc} ->
      args =
        case Jason.decode(tc.arguments) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %ToolCall{
        id: tc.id,
        name: tc.name,
        arguments: args
      }
    end)
  end
end
