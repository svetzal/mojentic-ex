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

      broker = Broker.new("llama3.2", Ollama)
      messages = [Message.user("Hello!")]
      {:ok, response} = Broker.generate(broker, messages)

  """

  @behaviour Mojentic.LLM.Gateway

  require Logger

  alias Mojentic.LLM.{
    Gateway,
    Message,
    GatewayResponse,
    ToolCall
  }

  @default_host "http://localhost:11434"
  # 5 minutes for larger models
  @default_timeout 300_000

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

    case HTTPoison.post(
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

    case HTTPoison.post(
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

    case HTTPoison.get("#{host}/api/tags", [], recv_timeout: timeout, timeout: timeout) do
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

    case HTTPoison.post(
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

  @doc """
  Pulls a model from the Ollama library.

  ## Examples

      iex> Ollama.pull_model("llama3.2")
      :ok

  """
  def pull_model(model) do
    host = get_host()
    timeout = get_timeout()

    body = %{name: model}

    case HTTPoison.post(
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

    case config.num_predict do
      nil when config.max_tokens > 0 ->
        Map.put(options, :num_predict, config.max_tokens)

      num when is_integer(num) and num > 0 ->
        Map.put(options, :num_predict, num)

      _ ->
        options
    end
  end

  defp maybe_add_tools(body, nil), do: body
  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) do
    tool_descriptors = Enum.map(tools, & &1.descriptor())
    Map.put(body, :tools, tool_descriptors)
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
    Map.put(ollama_msg, :images, image_paths)
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
end
