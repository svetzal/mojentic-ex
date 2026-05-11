defmodule Mojentic.LLM.Gateways.OpenAITest do
  use ExUnit.Case, async: true

  import Mox

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Gateways.OpenAI
  alias Mojentic.LLM.Message

  setup :verify_on_exit!

  defmodule EchoTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args) do
      {:ok, %{echoed: Map.get(args, "value", "nothing")}}
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "echo_tool",
          description: "Echoes the given value",
          parameters: %{
            type: "object",
            properties: %{
              value: %{type: "string", description: "Value to echo"}
            },
            required: ["value"]
          }
        }
      }
    end

    def matches?(name), do: name == "echo_tool"
  end

  describe "tool-call round-trip via Broker.generate/4" do
    test "correctly threads user→assistant(tool_calls)→tool messages through two HTTP calls" do
      tool_call_id = "call_abc123"

      # First response: assistant requests a tool call
      first_response =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => tool_call_id,
                    "type" => "function",
                    "function" => %{
                      "name" => "echo_tool",
                      "arguments" => Jason.encode!(%{"value" => "hello"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })

      # Second response: final assistant text after seeing tool result
      second_response =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "The echo result was: hello",
                "tool_calls" => nil
              },
              "finish_reason" => "stop"
            }
          ]
        })

      # Capture request bodies so we can assert on them
      test_pid = self()

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:request_body, 1, Jason.decode!(body)})
        {:ok, %{status_code: 200, body: first_response}}
      end)

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:request_body, 2, Jason.decode!(body)})
        {:ok, %{status_code: 200, body: second_response}}
      end)

      broker = Broker.new("gpt-4o", OpenAI)
      messages = [Message.user("Please echo hello")]

      assert {:ok, "The echo result was: hello"} =
               Broker.generate(broker, messages, [EchoTool])

      # Assert on the first request: should have exactly 1 user message
      assert_received {:request_body, 1, first_body}
      assert [user_msg] = first_body["messages"]
      assert user_msg["role"] == "user"
      assert user_msg["content"] == "Please echo hello"

      # Assert on the second request: should have 3 messages
      assert_received {:request_body, 2, second_body}
      assert [user_msg2, assistant_msg, tool_msg] = second_body["messages"]
      assert user_msg2["role"] == "user"

      # The assistant message must carry the tool_calls field
      assert assistant_msg["role"] == "assistant"
      assert [tc] = assistant_msg["tool_calls"]
      assert tc["id"] == tool_call_id
      assert tc["function"]["name"] == "echo_tool"

      # The tool result message must carry the tool_call_id and JSON-encoded result
      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == tool_call_id
      {:ok, tool_content} = Jason.decode(tool_msg["content"])
      assert tool_content["echoed"] == "hello"
    end
  end
end
