defmodule Mojentic.LLM.Broker do
  @moduledoc """
  Main interface for LLM interactions.

  The broker manages communication with LLM providers through gateways,
  handles tool calling with automatic recursion, and provides a clean
  API for text and structured output generation.

  ## Examples

      # Create a broker with Ollama
      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.Ollama

      broker = Broker.new("qwen3:32b", Ollama)

      # Generate a simple response
      messages = [Message.user("What is 2+2?")]
      {:ok, response} = Broker.generate(broker, messages)

      # Generate structured output
      schema = %{
        type: "object",
        properties: %{answer: %{type: "number"}},
        required: ["answer"]
      }
      {:ok, result} = Broker.generate_object(broker, messages, schema)

  ## Tool Support

  The broker automatically handles tool calls from the LLM. When the LLM
  requests a tool call, the broker will:

  1. Execute the tool with the provided arguments
  2. Add the tool result to the conversation
  3. Recursively call the LLM to generate the final response

  Example with tools:

      tools = [MyTool]
      {:ok, response} = Broker.generate(broker, messages, tools)

  """

  alias Mojentic.Error
  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.Gateway
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Message
  alias Mojentic.LLM.Tools.Tool
  alias Mojentic.Tracer

  require Logger

  @type t :: %__MODULE__{
          model: String.t(),
          gateway: Gateway.gateway(),
          correlation_id: String.t() | nil,
          tracer: pid() | :null_tracer
        }

  defstruct [:model, :gateway, :correlation_id, tracer: Tracer.null_tracer()]

  @doc """
  Creates a new LLM broker.

  ## Parameters

  - `model`: Model identifier (e.g., "qwen3:32b", "gpt-4")
  - `gateway`: Gateway module (e.g., `Mojentic.LLM.Gateways.Ollama`)
  - `opts`: Optional keyword list:
    - `:correlation_id` - Correlation ID for request tracking (default: auto-generated)
    - `:tracer` - Tracer system for observability (default: null_tracer)

  ## Examples

      iex> Broker.new("qwen3:32b", Mojentic.LLM.Gateways.Ollama)
      %Broker{model: "qwen3:32b", gateway: Mojentic.LLM.Gateways.Ollama, ...}

      iex> Broker.new("qwen3:32b", Mojentic.LLM.Gateways.Ollama, correlation_id: "custom-id-123")
      %Broker{model: "qwen3:32b", gateway: Mojentic.LLM.Gateways.Ollama, correlation_id: "custom-id-123"}

      iex> {:ok, tracer} = TracerSystem.start_link()
      iex> Broker.new("qwen3:32b", Mojentic.LLM.Gateways.Ollama, tracer: tracer)
      %Broker{model: "qwen3:32b", gateway: Mojentic.LLM.Gateways.Ollama, tracer: tracer}

  """
  def new(model, gateway, opts \\ []) do
    %__MODULE__{
      model: model,
      gateway: gateway,
      correlation_id: Keyword.get(opts, :correlation_id) || generate_correlation_id(),
      tracer: Keyword.get(opts, :tracer, Tracer.null_tracer())
    }
  end

  defp generate_correlation_id do
    UUID.uuid4()
  end

  @doc """
  Generates text response from the LLM.

  Handles tool calls automatically through recursion. When the LLM
  requests a tool call, the broker executes the tool and continues
  the conversation with the result.

  ## Parameters

  - `broker`: Broker instance
  - `messages`: List of conversation messages
  - `tools`: Optional list of tool modules (default: nil)
  - `config`: Optional completion configuration (default: default config)

  ## Returns

  - `{:ok, response_text}` on success
  - `{:error, reason}` on failure

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)
      messages = [Message.user("What is the capital of France?")]

      {:ok, response} = Broker.generate(broker, messages)
      # => {:ok, "The capital of France is Paris."}

      # With tools
      tools = [WeatherTool]
      messages = [Message.user("What's the weather in SF?")]
      {:ok, response} = Broker.generate(broker, messages, tools)

  """
  def generate(broker, messages, tools \\ nil, config \\ nil) do
    config = config || %CompletionConfig{}

    # Record LLM call in tracer
    tools_for_tracer = if tools, do: Enum.map(tools, &tool_descriptor/1), else: nil

    Tracer.record_llm_call(broker.tracer,
      model: broker.model,
      messages: messages,
      temperature: config.temperature,
      tools: tools_for_tracer,
      source: __MODULE__,
      correlation_id: broker.correlation_id
    )

    # Measure call duration
    start_time = System.monotonic_time(:millisecond)

    with {:ok, response} <-
           broker.gateway.complete(
             broker.model,
             messages,
             tools,
             config
           ) do
      call_duration_ms = System.monotonic_time(:millisecond) - start_time

      # Record LLM response in tracer
      Tracer.record_llm_response(broker.tracer,
        model: broker.model,
        content: response.content || "",
        tool_calls: response.tool_calls,
        call_duration_ms: call_duration_ms,
        source: __MODULE__,
        correlation_id: broker.correlation_id
      )

      case response.tool_calls do
        [] ->
          {:ok, response.content || ""}

        _tool_calls ->
          handle_tool_calls(
            broker,
            messages,
            response,
            tools,
            config
          )
      end
    end
  end

  @doc """
  Generates structured object response from the LLM.

  Uses JSON schema to enforce the structure of the response. The LLM
  will return a JSON object conforming to the provided schema.

  ## Parameters

  - `broker`: Broker instance
  - `messages`: List of conversation messages
  - `schema`: JSON schema for the expected response structure
  - `config`: Optional completion configuration (default: default config)

  ## Returns

  - `{:ok, parsed_object}` map conforming to schema on success
  - `{:error, reason}` on failure

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)

      schema = %{
        type: "object",
        properties: %{
          sentiment: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["sentiment", "confidence"]
      }

      messages = [Message.user("I love this!")]
      {:ok, result} = Broker.generate_object(broker, messages, schema)
      # => {:ok, %{"sentiment" => "positive", "confidence" => 0.95}}

  """
  def generate_object(broker, messages, schema, config \\ nil) do
    config = config || %CompletionConfig{}

    with {:ok, response} <-
           broker.gateway.complete_object(
             broker.model,
             messages,
             schema,
             config
           ) do
      case response.object do
        nil -> Error.invalid_response()
        object -> {:ok, object}
      end
    end
  end

  @doc """
  Generates streaming text response from the LLM.

  Yields content chunks as they arrive, and handles tool calls automatically
  through recursion. When tool calls are detected, the broker executes them
  and recursively streams the LLM's follow-up response.

  ## Parameters

  - `broker`: Broker instance
  - `messages`: List of conversation messages
  - `tools`: Optional list of tool modules (default: nil)
  - `config`: Optional completion configuration (default: default config)

  ## Returns

  A stream that yields content strings as they arrive.

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)
      messages = [Message.user("Tell me a story")]

      broker
      |> Broker.generate_stream(messages)
      |> Stream.each(&IO.write/1)
      |> Stream.run()

      # With tools
      tools = [DateTool]
      messages = [Message.user("What's the date tomorrow?")]

      broker
      |> Broker.generate_stream(messages, tools)
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  """
  def generate_stream(broker, messages, tools \\ nil, config \\ nil) do
    config = config || %CompletionConfig{}

    Stream.resource(
      fn -> initialize_stream(broker, messages, tools, config) end,
      fn state -> process_stream_element(state, broker, messages, tools, config) end,
      fn _ -> :ok end
    )
  end

  defp initialize_stream(broker, messages, tools, config) do
    stream = broker.gateway.complete_stream(broker.model, messages, tools, config)
    {stream, [], ""}
  end

  defp process_stream_element(
         {stream, acc_tool_calls, acc_content},
         broker,
         messages,
         tools,
         config
       ) do
    case Enum.take(stream, 1) do
      [{:content, chunk}] ->
        handle_content_chunk(chunk, stream, acc_tool_calls, acc_content)

      [{:tool_calls, tool_calls}] ->
        handle_tool_calls_chunk(tool_calls, stream, acc_tool_calls, acc_content)

      [{:error, reason}] ->
        handle_stream_error(reason)

      [] ->
        handle_stream_end(broker, messages, acc_tool_calls, acc_content, tools, config)
    end
  end

  defp process_stream_element(:halt, _broker, _messages, _tools, _config) do
    {:halt, nil}
  end

  defp process_stream_element({:recursive, recursive_stream}, _broker, _messages, _tools, _config) do
    handle_recursive_stream(recursive_stream)
  end

  defp handle_content_chunk(chunk, stream, acc_tool_calls, acc_content) do
    remaining_stream = Stream.drop(stream, 1)
    {[chunk], {remaining_stream, acc_tool_calls, acc_content <> chunk}}
  end

  defp handle_tool_calls_chunk(tool_calls, stream, acc_tool_calls, acc_content) do
    remaining_stream = Stream.drop(stream, 1)
    {[], {remaining_stream, acc_tool_calls ++ tool_calls, acc_content}}
  end

  defp handle_stream_error(reason) do
    Logger.error("Streaming error: #{inspect(reason)}")
    {:halt, nil}
  end

  defp handle_recursive_stream(recursive_stream) do
    case Enum.take(recursive_stream, 1) do
      [chunk] ->
        remaining = Stream.drop(recursive_stream, 1)
        {[chunk], {:recursive, remaining}}

      [] ->
        {:halt, nil}
    end
  end

  defp handle_stream_end(_broker, _messages, [], _acc_content, _tools, _config) do
    {:halt, nil}
  end

  defp handle_stream_end(_broker, _messages, _tool_calls, _acc_content, nil, _config) do
    Logger.warning("LLM requested tool calls but no tools provided")
    {:halt, nil}
  end

  defp handle_stream_end(_broker, _messages, _tool_calls, _acc_content, [], _config) do
    Logger.warning("LLM requested tool calls but no tools provided")
    {:halt, nil}
  end

  defp handle_stream_end(broker, messages, tool_calls, acc_content, tools, config) do
    Logger.info("Processing #{length(tool_calls)} tool call(s) in stream")

    response = build_gateway_response(acc_content, tool_calls)
    new_messages = messages ++ [build_assistant_message(response)]
    final_messages = execute_and_append_tool_results(broker, tool_calls, tools, new_messages)

    recursive_stream = generate_stream(broker, final_messages, tools, config)
    {[], {:recursive, recursive_stream}}
  end

  defp build_gateway_response(content, tool_calls) do
    %GatewayResponse{
      content: content,
      tool_calls: tool_calls,
      object: nil
    }
  end

  defp execute_and_append_tool_results(broker, tool_calls, tools, messages) do
    tool_results = Enum.map(tool_calls, &execute_tool(broker, &1, tools))

    Enum.reduce(tool_results, messages, fn
      {:ok, tool_message}, acc ->
        acc ++ [tool_message]

      {:error, reason}, acc ->
        Logger.error("Tool execution failed: #{Error.format_error(reason)}")
        acc
    end)
  end

  # Private functions

  defp handle_tool_calls(broker, messages, response, tools, config) do
    case tools do
      nil ->
        Logger.warning("LLM requested tool calls but no tools provided")
        {:ok, response.content || ""}

      [] ->
        Logger.warning("LLM requested tool calls but no tools provided")
        {:ok, response.content || ""}

      tools ->
        Logger.info("Processing #{length(response.tool_calls)} tool call(s)")

        # Add assistant message with tool calls
        new_messages = messages ++ [build_assistant_message(response)]

        # Execute all tool calls
        tool_results =
          Enum.map(response.tool_calls, fn tool_call ->
            execute_tool(broker, tool_call, tools)
          end)

        # Add tool result messages
        final_messages =
          Enum.reduce(tool_results, new_messages, fn
            {:ok, tool_message}, acc ->
              acc ++ [tool_message]

            {:error, reason}, acc ->
              Logger.error("Tool execution failed: #{Error.format_error(reason)}")
              acc
          end)

        # Recursively call generate with updated messages
        generate(broker, final_messages, tools, config)
    end
  end

  defp build_assistant_message(response) do
    %Message{
      role: :assistant,
      content: response.content,
      tool_calls: response.tool_calls
    }
  end

  defp execute_tool(broker, tool_call, tools) do
    case find_tool(tools, tool_call.name) do
      nil ->
        Logger.warning("Tool not found: #{tool_call.name}")
        Error.tool_error("Tool not found: #{tool_call.name}")

      tool ->
        Logger.info("Executing tool: #{tool_call.name}")

        # Measure tool execution time
        start_time = System.monotonic_time(:millisecond)

        case Tool.run(tool, tool_call.arguments) do
          {:ok, result} ->
            call_duration_ms = System.monotonic_time(:millisecond) - start_time

            # Record tool call in tracer
            Tracer.record_tool_call(broker.tracer,
              tool_name: tool_call.name,
              arguments: tool_call.arguments,
              result: result,
              caller: "Broker",
              call_duration_ms: call_duration_ms,
              source: __MODULE__,
              correlation_id: broker.correlation_id
            )

            {:ok,
             %Message{
               role: :tool,
               content: Jason.encode!(result),
               tool_calls: [tool_call]
             }}

          {:error, reason} ->
            call_duration_ms = System.monotonic_time(:millisecond) - start_time

            # Record failed tool call in tracer
            Tracer.record_tool_call(broker.tracer,
              tool_name: tool_call.name,
              arguments: tool_call.arguments,
              result: {:error, reason},
              caller: "Broker",
              call_duration_ms: call_duration_ms,
              source: __MODULE__,
              correlation_id: broker.correlation_id
            )

            Logger.error("Tool execution failed: #{Error.format_error(reason)}")
            Error.tool_error("Tool execution failed: #{Error.format_error(reason)}")
        end
    end
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn tool ->
      Tool.matches?(tool, name)
    end)
  end

  defp tool_descriptor(tool) do
    descriptor = Tool.descriptor(tool)
    function = descriptor["function"] || descriptor[:function]

    %{
      "name" => function["name"] || function[:name],
      "description" => function["description"] || function[:description]
    }
  end
end
