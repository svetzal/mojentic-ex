defmodule Mojentic.LLM.ChatSession do
  @moduledoc """
  Manages stateful conversation sessions with an LLM.

  ChatSession maintains conversation history with automatic context window
  management based on token counts. When the context exceeds the maximum
  token limit, the oldest messages are removed (preserving the system prompt).

  ## Features

  - Automatic message history tracking
  - Token-based context window management
  - Tool support through broker integration
  - Configurable system prompt and temperature
  - Tokenizer integration for accurate token counting

  ## Examples

      alias Mojentic.LLM.{Broker, ChatSession}
      alias Mojentic.LLM.Gateways.Ollama

      broker = Broker.new("qwen3:32b", Ollama)
      session = ChatSession.new(broker)

      {:ok, response} = ChatSession.send(session, "Hello!")
      # => {:ok, "Hello! How can I help you?", updated_session}

      # Continue conversation
      {:ok, response, session} = ChatSession.send(session, "Tell me a joke")

  ## With Tools

      alias Mojentic.LLM.Tools.DateResolver

      session = ChatSession.new(broker, tools: [DateResolver])
      {:ok, response, session} = ChatSession.send(session, "What day is tomorrow?")

  """

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.Gateways.TokenizerGateway
  alias Mojentic.LLM.Message

  require Logger

  @type t :: %__MODULE__{
          broker: Broker.t(),
          messages: [sized_message()],
          system_prompt: String.t(),
          tools: [module()] | nil,
          max_context: non_neg_integer(),
          tokenizer: TokenizerGateway.t(),
          temperature: float()
        }

  @type sized_message :: %{
          message: Message.t(),
          token_length: non_neg_integer()
        }

  @enforce_keys [:broker]
  defstruct [
    :broker,
    messages: [],
    system_prompt: "You are a helpful assistant.",
    tools: nil,
    max_context: 32_768,
    tokenizer: nil,
    temperature: 1.0
  ]

  @doc """
  Creates a new ChatSession.

  ## Options

  - `:system_prompt` - System prompt for the conversation (default: "You are a helpful assistant.")
  - `:tools` - List of tool modules to make available to the LLM (default: nil)
  - `:max_context` - Maximum token count for context window (default: 32,768)
  - `:tokenizer` - TokenizerGateway instance (default: auto-created with gpt2)
  - `:temperature` - Temperature for response generation (default: 1.0)

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)
      session = ChatSession.new(broker)

      # With custom options
      session = ChatSession.new(broker,
        system_prompt: "You are a coding assistant.",
        max_context: 16_384,
        temperature: 0.7
      )

      # With tools
      session = ChatSession.new(broker, tools: [MyTool])

  """
  @spec new(Broker.t(), keyword()) :: t()
  def new(broker, opts \\ []) do
    system_prompt = Keyword.get(opts, :system_prompt, "You are a helpful assistant.")
    tools = Keyword.get(opts, :tools)
    max_context = Keyword.get(opts, :max_context, 32_768)
    temperature = Keyword.get(opts, :temperature, 1.0)

    tokenizer =
      case Keyword.get(opts, :tokenizer) do
        nil ->
          # Create default tokenizer
          case TokenizerGateway.new() do
            {:ok, tokenizer} -> tokenizer
            {:error, reason} -> raise "Failed to create tokenizer: #{inspect(reason)}"
          end

        tokenizer ->
          tokenizer
      end

    session = %__MODULE__{
      broker: broker,
      system_prompt: system_prompt,
      tools: tools,
      max_context: max_context,
      tokenizer: tokenizer,
      temperature: temperature,
      messages: []
    }

    # Insert system message
    system_message = Message.system(system_prompt)
    insert_message(session, system_message)
  end

  @doc """
  Sends a query to the LLM and returns the response.

  The query is added as a user message, the LLM generates a response,
  and the response is added as an assistant message. Both are tracked
  in the conversation history.

  ## Parameters

  - `session` - The ChatSession instance
  - `query` - The user's query text

  ## Returns

  - `{:ok, response, updated_session}` - Success with response text and updated session
  - `{:error, reason}` - Error from broker

  ## Examples

      {:ok, response, session} = ChatSession.send(session, "What is 2+2?")
      # => {:ok, "2+2 equals 4.", updated_session}

      # Continue conversation
      {:ok, response, session} = ChatSession.send(session, "And what about 3+3?")

  """
  @spec send(t(), String.t()) :: {:ok, String.t(), t()} | {:error, term()}
  def send(session, query) do
    # Add user message
    session = insert_message(session, Message.user(query))

    # Generate response
    config = %CompletionConfig{temperature: session.temperature}

    # Extract just the messages (without token lengths) for broker
    messages = Enum.map(session.messages, & &1.message)

    case Broker.generate(session.broker, messages, session.tools, config) do
      {:ok, response} ->
        # Ensure all messages from broker response are sized
        # (broker may have added tool messages)
        session = ensure_all_messages_are_sized(session)

        # Add assistant response
        session = insert_message(session, Message.assistant(response))

        {:ok, response, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current message history.

  Messages are returned with their token lengths for debugging
  and monitoring context usage.

  ## Examples

      messages = ChatSession.messages(session)
      total_tokens = Enum.reduce(messages, 0, fn m, acc -> acc + m.token_length end)

  """
  @spec messages(t()) :: [sized_message()]
  def messages(session), do: session.messages

  @doc """
  Returns the total token count of all messages.

  ## Examples

      token_count = ChatSession.token_count(session)
      # => 1234

  """
  @spec token_count(t()) :: non_neg_integer()
  def token_count(session) do
    Enum.reduce(session.messages, 0, fn sized_msg, acc ->
      acc + sized_msg.token_length
    end)
  end

  # Private functions

  defp insert_message(session, message) do
    # Build sized message
    sized_message = build_sized_message(session.tokenizer, message)

    # Add to messages
    messages = session.messages ++ [sized_message]

    # Calculate total length
    total_length = Enum.reduce(messages, 0, fn msg, acc -> acc + msg.token_length end)

    # Trim if needed (keep system prompt at index 0)
    messages = trim_messages(messages, total_length, session.max_context)

    %{session | messages: messages}
  end

  defp build_sized_message(tokenizer, message) do
    token_length =
      case message.content do
        nil ->
          0

        content ->
          tokenizer
          |> TokenizerGateway.encode(content)
          |> length()
      end

    %{
      message: message,
      token_length: token_length
    }
  end

  defp trim_messages(messages, total_length, max_context) when total_length <= max_context do
    messages
  end

  defp trim_messages([system_msg | rest], total_length, max_context) do
    # Remove oldest non-system messages until we're under the limit
    # Always keep the system message at index 0
    trim_recursive(rest, total_length, max_context, [system_msg])
  end

  defp trim_recursive(messages, total_length, max_context, acc)
       when total_length <= max_context do
    Enum.reverse(acc) ++ messages
  end

  defp trim_recursive([oldest | rest], total_length, max_context, acc) do
    new_total = total_length - oldest.token_length
    trim_recursive(rest, new_total, max_context, acc)
  end

  defp trim_recursive([], _total_length, _max_context, acc) do
    # All messages removed (shouldn't happen in practice)
    Enum.reverse(acc)
  end

  defp ensure_all_messages_are_sized(session) do
    # This is needed because broker.generate() may modify the message list
    # (e.g., adding tool messages). In Python, this scans the message list
    # and converts any non-SizedLLMMessage to SizedLLMMessage.
    #
    # In our struct-based Elixir implementation, we maintain full control
    # of the message list and only add messages through insert_message,
    # so this is a no-op. Including for API compatibility and future-proofing.
    session
  end
end
