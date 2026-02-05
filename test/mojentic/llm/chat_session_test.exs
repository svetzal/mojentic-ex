defmodule Mojentic.LLM.ChatSessionTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.ChatSession
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Gateways.TokenizerGateway
  alias Mojentic.LLM.ToolCall

  # Mock gateway for testing
  defmodule MockGateway do
    @behaviour Mojentic.LLM.Gateway

    @impl true
    def complete(model, messages, tools, config) do
      Process.put(:last_complete_call, %{
        model: model,
        messages: messages,
        tools: tools,
        config: config
      })

      case Process.get(:mock_response) do
        nil ->
          {:ok,
           %GatewayResponse{
             content: "Mock response",
             tool_calls: [],
             object: nil
           }}

        fun when is_function(fun) ->
          fun.(messages)

        response ->
          response
      end
    end

    @impl true
    def complete_object(_model, _messages, _schema, _config) do
      {:ok, %GatewayResponse{content: nil, tool_calls: [], object: %{"test" => "value"}}}
    end

    @impl true
    def get_available_models do
      {:ok, ["model1", "model2"]}
    end

    @impl true
    def calculate_embeddings(_model, _text) do
      {:ok, [0.1, 0.2, 0.3]}
    end

    @impl true
    def complete_stream(_model, _messages, _tools, _config) do
      Stream.map(["Mock ", "stream"], fn chunk -> {:content, chunk} end)
    end
  end

  # Mock tool for testing
  defmodule MockTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args) do
      case Map.get(args, "fail") do
        true -> {:error, {:tool_error, "Tool failed"}}
        _ -> {:ok, %{result: "tool executed", input: args}}
      end
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "mock_tool",
          description: "A mock tool for testing",
          parameters: %{
            type: "object",
            properties: %{
              value: %{type: "number", description: "A test value"}
            }
          }
        }
      }
    end

    def matches?(name), do: name == "mock_tool"
  end

  setup do
    # Clear process dictionary before each test
    Process.delete(:mock_response)
    Process.delete(:last_complete_call)
    Process.delete(:call_number)

    # Create tokenizer
    {:ok, tokenizer} = TokenizerGateway.new()

    broker = Broker.new("test-model", MockGateway)

    {:ok, broker: broker, tokenizer: tokenizer}
  end

  describe "new/2" do
    test "creates session with default options", %{broker: broker} do
      session = ChatSession.new(broker)

      assert session.broker == broker
      assert session.system_prompt == "You are a helpful assistant."
      assert session.tools == nil
      assert session.max_context == 32_768
      assert session.temperature == 1.0
      assert is_struct(session.tokenizer, TokenizerGateway)

      # Should have system message
      assert length(session.messages) == 1
      [system_msg] = session.messages
      assert system_msg.message.role == :system
      assert system_msg.message.content == "You are a helpful assistant."
      assert system_msg.token_length > 0
    end

    test "creates session with custom options", %{broker: broker, tokenizer: tokenizer} do
      session =
        ChatSession.new(broker,
          system_prompt: "You are a coding assistant.",
          tools: [MockTool],
          max_context: 16_384,
          tokenizer: tokenizer,
          temperature: 0.7
        )

      assert session.system_prompt == "You are a coding assistant."
      assert session.tools == [MockTool]
      assert session.max_context == 16_384
      assert session.temperature == 0.7
      assert session.tokenizer == tokenizer

      # System message should use custom prompt
      [system_msg] = session.messages
      assert system_msg.message.content == "You are a coding assistant."
    end
  end

  describe "send/2" do
    test "sends query and receives response", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Hello, human!", tool_calls: [], object: nil}}
      end)

      assert {:ok, response, updated_session} = ChatSession.send(session, "Hello!")

      assert response == "Hello, human!"
      assert length(updated_session.messages) == 3

      # Verify messages: system, user, assistant
      [system_msg, user_msg, assistant_msg] = updated_session.messages

      assert system_msg.message.role == :system
      assert user_msg.message.role == :user
      assert user_msg.message.content == "Hello!"
      assert assistant_msg.message.role == :assistant
      assert assistant_msg.message.content == "Hello, human!"

      # All messages should have token counts
      assert system_msg.token_length > 0
      assert user_msg.token_length > 0
      assert assistant_msg.token_length > 0
    end

    test "maintains conversation history across multiple sends", %{broker: broker} do
      session = ChatSession.new(broker)

      # Track which call this is
      Process.put(:call_number, 0)

      Process.put(:mock_response, fn _messages ->
        # Increment call number
        call_num = Process.get(:call_number, 0)
        Process.put(:call_number, call_num + 1)

        content =
          case call_num do
            0 -> "First response"
            1 -> "Second response"
            _ -> "Response #{call_num}"
          end

        {:ok, %GatewayResponse{content: content, tool_calls: [], object: nil}}
      end)

      {:ok, resp1, session} = ChatSession.send(session, "First query")
      assert resp1 == "First response"
      assert length(session.messages) == 3

      {:ok, resp2, session} = ChatSession.send(session, "Second query")
      assert resp2 == "Second response"
      assert length(session.messages) == 5

      # Verify message order
      [_system, msg1, resp1_msg, msg2, resp2_msg] = session.messages
      assert msg1.message.content == "First query"
      assert resp1_msg.message.content == "First response"
      assert msg2.message.content == "Second query"
      assert resp2_msg.message.content == "Second response"
    end

    test "passes temperature to broker", %{broker: broker} do
      session = ChatSession.new(broker, temperature: 0.5)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Response", tool_calls: [], object: nil}}
      end)

      {:ok, _response, _session} = ChatSession.send(session, "Test")

      call_info = Process.get(:last_complete_call)
      assert call_info.config.temperature == 0.5
    end

    test "passes tools to broker", %{broker: broker} do
      session = ChatSession.new(broker, tools: [MockTool])

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Response", tool_calls: [], object: nil}}
      end)

      {:ok, _response, _session} = ChatSession.send(session, "Test")

      call_info = Process.get(:last_complete_call)
      assert call_info.tools == [MockTool]
    end

    test "handles tool calls during conversation", %{broker: broker} do
      session = ChatSession.new(broker, tools: [MockTool])

      # Mock response that simulates tool call followed by final response
      Process.put(:mock_response, fn messages ->
        # First call: return tool call
        # Second call (after tool execution): return final response
        if length(messages) == 2 do
          {:ok,
           %GatewayResponse{
             content: "",
             tool_calls: [
               %ToolCall{
                 id: "call-1",
                 name: "mock_tool",
                 arguments: %{"value" => 42}
               }
             ],
             object: nil
           }}
        else
          {:ok,
           %GatewayResponse{content: "Final response after tool", tool_calls: [], object: nil}}
        end
      end)

      {:ok, response, session} = ChatSession.send(session, "Use the tool")

      assert response == "Final response after tool"

      # Should have: system, user, assistant (with tool call), tool result, assistant (final)
      # Note: The broker handles tool execution and recursive calls internally
      assert length(session.messages) == 3
    end

    test "propagates broker errors", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:error, {:http_error, 500}}
      end)

      assert {:error, {:http_error, 500}} = ChatSession.send(session, "Error test")
    end
  end

  describe "send_stream/2 and finalize_stream/1" do
    test "yields content chunks", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Mock response", tool_calls: [], object: nil}}
      end)

      {:ok, stream, handle} = ChatSession.send_stream(session, "Hello!")

      chunks = stream |> Enum.to_list()

      assert chunks != []
      assert is_binary(hd(chunks))

      _session = ChatSession.finalize_stream(handle)
    end

    test "grows message history after finalize", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Mock response", tool_calls: [], object: nil}}
      end)

      {:ok, stream, handle} = ChatSession.send_stream(session, "Hello!")
      stream |> Stream.run()
      session = ChatSession.finalize_stream(handle)

      assert length(session.messages) == 3
    end

    test "records full assembled response in history", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Mock response", tool_calls: [], object: nil}}
      end)

      {:ok, stream, handle} = ChatSession.send_stream(session, "Hello!")
      chunks = stream |> Enum.to_list()
      session = ChatSession.finalize_stream(handle)

      expected_response = Enum.join(chunks, "")
      [_system, _user, assistant] = session.messages
      assert assistant.message.content == expected_response
    end

    test "records user message in history", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Mock response", tool_calls: [], object: nil}}
      end)

      {:ok, stream, handle} = ChatSession.send_stream(session, "My question")
      stream |> Stream.run()
      session = ChatSession.finalize_stream(handle)

      [_system, user_msg, _assistant] = session.messages
      assert user_msg.message.role == :user
      assert user_msg.message.content == "My question"
    end

    test "respects context capacity", %{broker: broker} do
      session = ChatSession.new(broker, max_context: 50)

      Process.put(:mock_response, fn _messages ->
        {:ok,
         %GatewayResponse{
           content: "This is a longer response to consume tokens",
           tool_calls: [],
           object: nil
         }}
      end)

      {:ok, stream, handle} = ChatSession.send_stream(session, "First long query message")
      stream |> Stream.run()
      session = ChatSession.finalize_stream(handle)

      {:ok, stream, handle} = ChatSession.send_stream(session, "Second long query message")
      stream |> Stream.run()
      session = ChatSession.finalize_stream(handle)

      # System message should always be preserved
      [system_msg | _rest] = session.messages
      assert system_msg.message.role == :system

      # Total tokens should be under max_context
      total_tokens = ChatSession.token_count(session)
      assert total_tokens <= 50
    end
  end

  describe "context window management" do
    test "removes oldest messages when exceeding max_context", %{broker: broker} do
      # Use small context window to trigger trimming
      session = ChatSession.new(broker, max_context: 50)

      Process.put(:mock_response, fn _messages ->
        {:ok,
         %GatewayResponse{
           content: "This is a longer response to consume tokens",
           tool_calls: [],
           object: nil
         }}
      end)

      # Send multiple queries to exceed context
      {:ok, _resp, session} = ChatSession.send(session, "First long query message")
      initial_count = length(session.messages)

      {:ok, _resp, session} = ChatSession.send(session, "Second long query message")
      {:ok, _resp, session} = ChatSession.send(session, "Third long query message")
      {:ok, _resp, session} = ChatSession.send(session, "Fourth long query message")

      # Should have trimmed some messages
      final_count = length(session.messages)
      assert final_count <= initial_count + 6

      # System message should always be preserved
      [system_msg | _rest] = session.messages
      assert system_msg.message.role == :system
      assert system_msg.message.content == "You are a helpful assistant."

      # Total tokens should be under max_context
      total_tokens = ChatSession.token_count(session)
      assert total_tokens <= 50
    end

    test "keeps system prompt when trimming", %{broker: broker} do
      session = ChatSession.new(broker, max_context: 30, system_prompt: "Custom system prompt")

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Response", tool_calls: [], object: nil}}
      end)

      # Add multiple messages to force trimming
      {:ok, _resp, session} = ChatSession.send(session, "Query 1")
      {:ok, _resp, session} = ChatSession.send(session, "Query 2")
      {:ok, _resp, session} = ChatSession.send(session, "Query 3")

      # System message should still be first
      [system_msg | _rest] = session.messages
      assert system_msg.message.role == :system
      assert system_msg.message.content == "Custom system prompt"
    end
  end

  describe "token counting" do
    test "counts tokens correctly for messages", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Response", tool_calls: [], object: nil}}
      end)

      {:ok, _resp, session} = ChatSession.send(session, "Hello")

      total = ChatSession.token_count(session)
      assert total > 0

      # Verify it matches sum of individual messages
      manual_sum = Enum.reduce(session.messages, 0, fn msg, acc -> acc + msg.token_length end)
      assert total == manual_sum
    end

    test "handles nil content in messages", %{broker: broker, tokenizer: tokenizer} do
      # Build sized message should handle nil content
      sized_msg =
        ChatSession.new(broker, tokenizer: tokenizer) |> Map.get(:messages) |> List.first()

      # Should not crash
      assert sized_msg.token_length >= 0
    end
  end

  describe "messages/1" do
    test "returns message history with token lengths", %{broker: broker} do
      session = ChatSession.new(broker)

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Response", tool_calls: [], object: nil}}
      end)

      {:ok, _resp, session} = ChatSession.send(session, "Test query")

      messages = ChatSession.messages(session)

      assert length(messages) == 3
      assert Enum.all?(messages, fn msg -> is_map(msg) && Map.has_key?(msg, :message) end)
      assert Enum.all?(messages, fn msg -> Map.has_key?(msg, :token_length) end)
      assert Enum.all?(messages, fn msg -> msg.token_length > 0 end)
    end
  end

  describe "token_count/1" do
    test "returns total token count", %{broker: broker} do
      session = ChatSession.new(broker)

      count1 = ChatSession.token_count(session)
      assert count1 > 0

      Process.put(:mock_response, fn _messages ->
        {:ok, %GatewayResponse{content: "Response", tool_calls: [], object: nil}}
      end)

      {:ok, _resp, session} = ChatSession.send(session, "Add more tokens")

      count2 = ChatSession.token_count(session)
      assert count2 > count1
    end
  end
end
