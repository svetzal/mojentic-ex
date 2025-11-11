defmodule Mojentic.LLM.Gateways.OllamaTest do
  use ExUnit.Case, async: true

  import Mox

  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.GatewayResponse
  alias Mojentic.LLM.Gateways.Ollama
  alias Mojentic.LLM.Message

  setup :verify_on_exit!

  describe "complete/4" do
    test "successfully completes with valid response" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Hi there!",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, %GatewayResponse{content: "Hi there!", tool_calls: []}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles tool calls in response" do
      messages = [Message.user("Use a tool")]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "",
            "role" => "assistant",
            "tool_calls" => [
              %{
                "id" => "call_123",
                "function" => %{
                  "name" => "test_tool",
                  "arguments" => %{"arg" => "value"}
                }
              }
            ]
          }
        })

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, %GatewayResponse{content: "", tool_calls: [tool_call]}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)

      assert tool_call.id == "call_123"
      assert tool_call.name == "test_tool"
      assert tool_call.arguments == %{"arg" => "value"}
    end

    test "handles HTTP errors" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Server error"}}
      end)

      assert {:error, {:http_error, 500}} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles request failures" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, {:request_failed, :timeout}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles invalid JSON response" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: "invalid json"}}
      end)

      assert {:error, :invalid_response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end
  end

  describe "complete_object/4" do
    test "successfully completes with valid JSON object" do
      messages = [Message.user("Generate data")]
      schema = %{type: "object", properties: %{name: %{type: "string"}}}
      config = CompletionConfig.new()

      object_content = Jason.encode!(%{"name" => "test"})

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => object_content,
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, %GatewayResponse{content: ^object_content, object: %{"name" => "test"}}} =
               Ollama.complete_object("qwen2.5:3b", messages, schema, config)
    end

    test "handles invalid JSON in content" do
      messages = [Message.user("Generate data")]
      schema = %{type: "object"}
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "not valid json",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:error, :invalid_json_object} =
               Ollama.complete_object("qwen2.5:3b", messages, schema, config)
    end

    test "handles HTTP errors" do
      messages = [Message.user("Generate data")]
      schema = %{type: "object"}
      config = CompletionConfig.new()

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 404, body: "Not found"}}
      end)

      assert {:error, {:http_error, 404}} =
               Ollama.complete_object("qwen2.5:3b", messages, schema, config)
    end
  end

  describe "get_available_models/0" do
    test "successfully retrieves model list" do
      response_body =
        Jason.encode!(%{
          "models" => [
            %{"name" => "qwen2.5:3b"},
            %{"name" => "llama3:8b"}
          ]
        })

      expect(HTTPoisonMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, ["qwen2.5:3b", "llama3:8b"]} = Ollama.get_available_models()
    end

    test "handles HTTP errors" do
      expect(HTTPoisonMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Error"}}
      end)

      assert {:error, {:http_error, 500}} = Ollama.get_available_models()
    end

    test "handles request failures" do
      expect(HTTPoisonMock, :get, fn _url, _headers, _opts ->
        {:error, :econnrefused}
      end)

      assert {:error, {:request_failed, :econnrefused}} = Ollama.get_available_models()
    end

    test "handles invalid response format" do
      expect(HTTPoisonMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      assert {:error, :invalid_response} = Ollama.get_available_models()
    end
  end

  describe "calculate_embeddings/2" do
    test "successfully calculates embeddings" do
      response_body = Jason.encode!(%{"embedding" => [0.1, 0.2, 0.3]})

      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, [0.1, 0.2, 0.3]} =
               Ollama.calculate_embeddings("test text", "mxbai-embed-large")
    end

    test "uses default model when nil provided" do
      response_body = Jason.encode!(%{"embedding" => [0.1]})

      expect(HTTPoisonMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["model"] == "mxbai-embed-large"
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, [0.1]} = Ollama.calculate_embeddings("test", nil)
    end

    test "handles HTTP errors" do
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 400, body: "Bad request"}}
      end)

      assert {:error, {:http_error, 400}} = Ollama.calculate_embeddings("test", "model")
    end

    test "handles invalid response format" do
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      assert {:error, :invalid_response} = Ollama.calculate_embeddings("test", "model")
    end
  end

  describe "pull_model/1" do
    test "successfully pulls a model" do
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: ""}}
      end)

      assert :ok = Ollama.pull_model("qwen2.5:3b")
    end

    test "handles HTTP errors" do
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 404, body: "Model not found"}}
      end)

      assert {:error, {:http_error, 404}} = Ollama.pull_model("nonexistent")
    end

    test "handles request failures" do
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:error, :network_error}
      end)

      assert {:error, {:request_failed, :network_error}} = Ollama.pull_model("model")
    end
  end

  describe "tool integration" do
    defmodule MockTool do
      @behaviour Mojentic.LLM.Tools.Tool

      @impl true
      def run(_args), do: {:ok, %{result: "test"}}

      @impl true
      def descriptor do
        %{
          type: "function",
          function: %{
            name: "mock_tool",
            description: "A mock tool",
            parameters: %{type: "object", properties: %{}}
          }
        }
      end

      def matches?("mock_tool"), do: true
      def matches?(_), do: false
    end

    test "includes tools in request when provided" do
      messages = [Message.user("Use a tool")]
      config = CompletionConfig.new()
      tools = [MockTool]

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Using tool",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert is_list(decoded["tools"])
        assert length(decoded["tools"]) == 1
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, tools, config)
    end
  end

  describe "message adaptation" do
    test "adapts messages with images" do
      messages = [
        Message.user("Describe this") |> Message.with_images(["image1.jpg", "image2.jpg"])
      ]

      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert hd(decoded["messages"])["images"] == ["image1.jpg", "image2.jpg"]
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "adapts messages with tool calls" do
      tool_call = %Mojentic.LLM.ToolCall{
        id: "call_123",
        name: "test_tool",
        arguments: %{"key" => "value"}
      }

      messages = [%Message{role: :assistant, content: "", tool_calls: [tool_call]}]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        assert is_list(msg["tool_calls"])
        assert hd(msg["tool_calls"])["function"]["name"] == "test_tool"
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end
  end

  describe "configuration" do
    test "respects CompletionConfig settings" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        num_predict: nil
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["options"]["temperature"] == 0.7
        assert decoded["options"]["num_ctx"] == 2048
        assert decoded["options"]["num_predict"] == 100
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "uses num_predict when provided directly" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.5,
        max_tokens: 50,
        num_ctx: 1024,
        num_predict: 200
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(HTTPoisonMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["options"]["num_predict"] == 200
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end
  end
end
