defmodule Mojentic.LLM.Gateways.OpenAIToolRoundtripTest do
  use ExUnit.Case, async: true

  import Mox

  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Gateways.OpenAI
  alias Mojentic.LLM.Message

  setup :verify_on_exit!

  @fixtures_dir Path.join([__DIR__, "..", "..", "..", "fixtures", "openai_tool_roundtrip"])

  defmodule GetWeatherTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @tool_result Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "fixtures",
                   "openai_tool_roundtrip",
                   "tool-result.json"
                 ])
                 |> File.read!()
                 |> Jason.decode!()

    @impl true
    def run(_tool, args) do
      send(self(), {:weather_tool_called, args})
      {:ok, @tool_result}
    end

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "get_weather",
          description: "Get the current weather for a location",
          parameters: %{
            type: "object",
            properties: %{
              location: %{type: "string", description: "The city or location to get weather for"}
            },
            required: ["location"]
          }
        }
      }
    end

    def matches?(name), do: name == "get_weather"
  end

  describe "tool-call round-trip via Broker.generate/4" do
    test "correctly threads user→assistant(tool_calls)→tool messages through two HTTP calls" do
      test_pid = self()

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:request_body, 1, Jason.decode!(body)})

        {:ok,
         %{
           status_code: 200,
           body: File.read!(Path.join(@fixtures_dir, "response-1-tool-call.json"))
         }}
      end)

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:request_body, 2, Jason.decode!(body)})

        {:ok,
         %{
           status_code: 200,
           body: File.read!(Path.join(@fixtures_dir, "response-2-final.json"))
         }}
      end)

      broker = Broker.new("gpt-4o", OpenAI)

      assert {:ok, "It's currently 22°C and sunny in Paris."} =
               Broker.generate(broker, [Message.user("What's the weather in Paris?")], [
                 GetWeatherTool
               ])

      # (1) First request body includes a tool named get_weather
      assert_received {:request_body, 1, body1}
      assert Enum.any?(body1["tools"] || [], &(&1["function"]["name"] == "get_weather"))

      # (2) The get_weather tool was invoked with location == "Paris"
      assert_received {:weather_tool_called, weather_args}
      assert weather_args["location"] == "Paris"

      # (3) Second request body carries the full conversation history
      assert_received {:request_body, 2, body2}
      msgs = body2["messages"]

      # Contains the original user message
      assert Enum.any?(
               msgs,
               &(&1["role"] == "user" and &1["content"] == "What's the weather in Paris?")
             )

      # Contains an assistant message with tool_calls
      assistant_msg = Enum.find(msgs, &(&1["role"] == "assistant" and is_list(&1["tool_calls"])))
      assert assistant_msg

      args_str = assistant_msg["tool_calls"] |> hd() |> get_in(["function", "arguments"])
      assert is_binary(args_str)
      # arguments is a JSON string that decodes to a map — not a double-encoded string
      assert Jason.decode!(args_str) == %{"location" => "Paris"}

      # Contains a tool-role message with tool_call_id (not a tool_calls array)
      tool_msg = Enum.find(msgs, &(&1["role"] == "tool"))
      assert tool_msg
      assert tool_msg["tool_call_id"] == "call_fixture_get_weather"
      refute Map.has_key?(tool_msg, "tool_calls")
      assert is_binary(tool_msg["content"])

      assert Jason.decode!(tool_msg["content"]) == %{
               "temperature_c" => 22,
               "conditions" => "sunny"
             }

      # (4) Final broker result matches the second fixture's response text
      # (already asserted above via Broker.generate return value)
    end
  end
end
