defmodule Mojentic.LLM.Gateways.Ollama do
  @moduledoc """
  Gateway for Ollama local LLM service.

  This gateway provides access to local LLM models through Ollama,
  supporting text generation, structured output, tool calling,
  and embeddings.

  ## Configuration

  Set environment variables to configure the gateway:

      export OLLAMA_HOST=http://localhost:11434
      export OLLAMA_TIMEOUT=300000  # 5 minutes in milliseconds (default)

  The timeout is especially important for larger models which may take
  longer to generate responses.

  ## Examples

      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.Ollama

      broker = Broker.new("qwen3:32b", Ollama)
      messages = [Message.user("Hello!")]
      {:ok, response} = Broker.generate(broker, messages)

  """

  @behaviour Mojentic.LLM.Gateway

  alias Mojentic.LLM.Gateway
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Message
  alias Mojentic.LLM.ToolCall
  alias Mojentic.LLM.Tools.Tool

  require Logger

  @default_host "http://localhost:11434"
  # 5 minutes for larger models
  @default_timeout 300_000

  defp http_client do
    Application.get_env(:mojentic, :http_client, HTTPoison)
  end

  @impl Gateway
  def complete(model, messages, tools, config) do
    host = get_host()
    timeout = get_timeout()

    ollama_messages = adapt_messages(messages)
    options = extract_options(config)

    body = %{
      model: model,
      messages: ollama_messages,
      options: options,
      stream: false
    }

    body = maybe_add_tools(body, tools)
    body = maybe_add_format(body, config)

    case http_client().post(
           "#{host}/api/chat",
           Jason.encode!(body),
           [{"Content-Type", "application/json"}],
           recv_timeout: timeout,
           timeout: timeout
         ) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_response(response_body)

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl Gateway
  def complete_object(model, messages, schema, config) do
    host = get_host()
    timeout = get_timeout()

    ollama_messages = adapt_messages(messages)
    options = extract_options(config)

    body = %{
      model: model,
      messages: ollama_messages,
      options: options,
      format: schema,
      stream: false
    }

    case http_client().post(
           "#{host}/api/chat",
           Jason.encode!(body),
           [{"Content-Type", "application/json"}],
           recv_timeout: timeout,
           timeout: timeout
         ) do
      {:ok, %{status_code: 200, body: response_body}} ->
        parse_object_response(response_body)

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl Gateway
  def get_available_models do
    host = get_host()
    timeout = get_timeout()

    case http_client().get("#{host}/api/tags", [], recv_timeout: timeout, timeout: timeout) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"models" => models}} ->
            names = Enum.map(models, & &1["name"])
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
    host = get_host()
    timeout = get_timeout()
    model = model || "mxbai-embed-large"

    body = %{
      model: model,
      prompt: text
    }

    case http_client().post(
           "#{host}/api/embeddings",
           Jason.encode!(body),
           [{"Content-Type", "application/json"}],
           recv_timeout: timeout,
           timeout: timeout
         ) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"embedding" => embedding}} ->
            {:ok, embedding}

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
  def complete_stream(model, messages, tools, config) do
    host = get_host()
    timeout = get_timeout()

    ollama_messages = adapt_messages(messages)
    options = extract_options(config)

    body = %{
      model: model,
      messages: ollama_messages,
      options: options,
      stream: true
    }

    body = maybe_add_tools(body, tools)
    body = maybe_add_format(body, config)

    Stream.resource(
      # Start function - initiate the streaming request
      fn ->
        case http_client().post(
               "#{host}/api/chat",
               Jason.encode!(body),
               [{"Content-Type", "application/json"}],
               recv_timeout: timeout,
               timeout: timeout,
               stream_to: self(),
               async: :once
             ) do
          {:ok, %HTTPoison.AsyncResponse{id: id}} ->
            {id, "", []}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      # Next function - process incoming chunks
      fn
        :halt ->
          {:halt, :halt}

        {:error, _reason} = error ->
          {[error], :halt}

        {id, buffer, acc_tool_calls} ->
          receive do
            %HTTPoison.AsyncStatus{id: ^id} ->
              http_client().stream_next(%HTTPoison.AsyncResponse{id: id})
              {[], {id, buffer, acc_tool_calls}}

            %HTTPoison.AsyncHeaders{id: ^id} ->
              http_client().stream_next(%HTTPoison.AsyncResponse{id: id})
              {[], {id, buffer, acc_tool_calls}}

            %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
              http_client().stream_next(%HTTPoison.AsyncResponse{id: id})
              parse_streaming_chunks(chunk, buffer, acc_tool_calls, id)

            %HTTPoison.AsyncEnd{id: ^id} ->
              # Stream finished - yield accumulated tool calls if any
              result =
                if acc_tool_calls != [] do
                  [{:tool_calls, Enum.reverse(acc_tool_calls)}]
                else
                  []
                end

              {result, :halt}
          after
            timeout ->
              {[{:error, :timeout}], :halt}
          end
      end,
      # After function - cleanup
      fn
        :halt -> :ok
        {:error, _} -> :ok
        _ -> :ok
      end
    )
  end

  @doc """
  Pulls a model from the Ollama library.

  ## Examples

      iex> Ollama.pull_model("qwen3:32b")
      :ok

  """
  def pull_model(model) do
    host = get_host()
    timeout = get_timeout()

    body = %{name: model}

    case http_client().post(
           "#{host}/api/pull",
           Jason.encode!(body),
           [{"Content-Type", "application/json"}],
           recv_timeout: timeout,
           timeout: timeout
         ) do
      {:ok, %{status_code: 200}} ->
        :ok

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # Private functions

  defp get_host do
    System.get_env("OLLAMA_HOST") || @default_host
  end

  defp get_timeout do
    case System.get_env("OLLAMA_TIMEOUT") do
      nil ->
        @default_timeout

      timeout_str ->
        case Integer.parse(timeout_str) do
          {timeout, _} -> timeout
          :error -> @default_timeout
        end
    end
  end

  defp extract_options(config) do
    options = %{
      temperature: config.temperature,
      num_ctx: config.num_ctx
    }

    options =
      case config.num_predict do
        nil when config.max_tokens > 0 ->
          Map.put(options, :num_predict, config.max_tokens)

        num when is_integer(num) and num > 0 ->
          Map.put(options, :num_predict, num)

        _ ->
          options
      end

    options =
      if config.top_p do
        Map.put(options, :top_p, config.top_p)
      else
        options
      end

    options =
      if config.top_k do
        Map.put(options, :top_k, config.top_k)
      else
        options
      end

    options
  end

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    tool_descriptors = Enum.map(tools, &Tool.descriptor/1)
    Map.put(body, :tools, tool_descriptors)
  end

  defp maybe_add_format(body, config) do
    case config.response_format do
      %{type: :json_object, schema: schema} when not is_nil(schema) ->
        Map.put(body, :format, schema)

      %{type: :json_object} ->
        Map.put(body, :format, "json")

      _ ->
        body
    end
  end

  defp adapt_messages(messages) do
    Enum.map(messages, &adapt_message/1)
  end

  defp adapt_message(%Message{} = message) do
    ollama_msg = %{
      role: role_to_string(message.role),
      content: message.content || ""
    }

    ollama_msg = maybe_add_images(ollama_msg, message.image_paths)
    maybe_add_tool_calls(ollama_msg, message.tool_calls)
  end

  defp role_to_string(:system), do: "system"
  defp role_to_string(:user), do: "user"
  defp role_to_string(:assistant), do: "assistant"
  defp role_to_string(:tool), do: "tool"

  defp maybe_add_images(ollama_msg, nil), do: ollama_msg
  defp maybe_add_images(ollama_msg, []), do: ollama_msg

  defp maybe_add_images(ollama_msg, image_paths) do
    # Ollama expects base64-encoded images, not file paths
    encoded_images =
      Enum.map(image_paths, fn path ->
        case File.read(path) do
          {:ok, binary} ->
            Base.encode64(binary)

          {:error, reason} ->
            Logger.error("Failed to read image file: #{path}, reason: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    Map.put(ollama_msg, :images, encoded_images)
  end

  defp maybe_add_tool_calls(ollama_msg, nil), do: ollama_msg
  defp maybe_add_tool_calls(ollama_msg, []), do: ollama_msg

  defp maybe_add_tool_calls(ollama_msg, tool_calls) do
    calls =
      Enum.map(tool_calls, fn tc ->
        %{
          type: "function",
          function: %{
            name: tc.name,
            arguments: tc.arguments
          }
        }
      end)

    Map.put(ollama_msg, :tool_calls, calls)
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message}} ->
        content = Map.get(message, "content")
        tool_calls = parse_tool_calls(message)

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
      {:ok, %{"message" => %{"content" => content}}} ->
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

  defp parse_tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    Enum.map(tool_calls, fn call ->
      %ToolCall{
        id: call["id"],
        name: get_in(call, ["function", "name"]),
        arguments: get_in(call, ["function", "arguments"]) || %{}
      }
    end)
  end

  defp parse_tool_calls(_), do: []

  # Parse streaming chunks from Ollama
  # Ollama sends newline-delimited JSON objects
  defp parse_streaming_chunks(chunk, buffer, acc_tool_calls, id) do
    # Append chunk to buffer
    new_buffer = buffer <> chunk

    # Split on newlines to process complete JSON objects
    lines = String.split(new_buffer, "\n", trim: true)

    # The last line might be incomplete, so keep it in the buffer
    {complete_lines, remaining_buffer} =
      if String.ends_with?(new_buffer, "\n") do
        {lines, ""}
      else
        case Enum.split(lines, -1) do
          {complete, [incomplete]} -> {complete, incomplete}
          {complete, []} -> {complete, ""}
        end
      end

    # Process each complete line
    {results, new_acc_tool_calls} =
      Enum.reduce(complete_lines, {[], acc_tool_calls}, fn line, {acc_results, acc_tools} ->
        case Jason.decode(line) do
          {:ok, %{"message" => message, "done" => false}} ->
            # Content chunk
            content = Map.get(message, "content")
            tool_calls = parse_tool_calls(message)

            new_results =
              if content && content != "" do
                [{:content, content} | acc_results]
              else
                acc_results
              end

            new_tools = if tool_calls != [], do: acc_tools ++ tool_calls, else: acc_tools

            {new_results, new_tools}

          {:ok, %{"done" => true}} ->
            # Final chunk - don't emit anything here, will be handled in AsyncEnd
            {acc_results, acc_tools}

          {:error, _} ->
            Logger.warning("Failed to parse streaming chunk: #{line}")
            {acc_results, acc_tools}

          _ ->
            {acc_results, acc_tools}
        end
      end)

    # Return reversed results (they were prepended) and continue with new state
    {Enum.reverse(results), {id, remaining_buffer, new_acc_tool_calls}}
  end
end
