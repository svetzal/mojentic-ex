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

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Server error"}}
      end)

      assert {:error, {:http_error, 500}} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles request failures" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:error, {:request_failed, :timeout}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles invalid JSON response" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:error, :invalid_json_object} =
               Ollama.complete_object("qwen2.5:3b", messages, schema, config)
    end

    test "handles HTTP errors" do
      messages = [Message.user("Generate data")]
      schema = %{type: "object"}
      config = CompletionConfig.new()

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, ["qwen2.5:3b", "llama3:8b"]} = Ollama.get_available_models()
    end

    test "handles HTTP errors" do
      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Error"}}
      end)

      assert {:error, {:http_error, 500}} = Ollama.get_available_models()
    end

    test "handles request failures" do
      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:error, :econnrefused}
      end)

      assert {:error, {:request_failed, :econnrefused}} = Ollama.get_available_models()
    end

    test "handles invalid response format" do
      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      assert {:error, :invalid_response} = Ollama.get_available_models()
    end
  end

  describe "calculate_embeddings/2" do
    test "successfully calculates embeddings" do
      response_body = Jason.encode!(%{"embedding" => [0.1, 0.2, 0.3]})

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, [0.1, 0.2, 0.3]} =
               Ollama.calculate_embeddings("test text", "mxbai-embed-large")
    end

    test "uses default model when nil provided" do
      response_body = Jason.encode!(%{"embedding" => [0.1]})

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["model"] == "mxbai-embed-large"
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, [0.1]} = Ollama.calculate_embeddings("test", nil)
    end

    test "handles HTTP errors" do
      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 400, body: "Bad request"}}
      end)

      assert {:error, {:http_error, 400}} = Ollama.calculate_embeddings("test", "model")
    end

    test "handles invalid response format" do
      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: "{}"}}
      end)

      assert {:error, :invalid_response} = Ollama.calculate_embeddings("test", "model")
    end
  end

  describe "pull_model/1 and pull_model/2" do
    test "successfully pulls a model without progress callback" do
      model = "qwen2.5:3b"

      pull_status =
        Jason.encode!(%{"status" => "downloading", "completed" => 100, "total" => 1000})

      pull_complete = Jason.encode!(%{"status" => "success"})
      stream_data = pull_status <> "\n" <> pull_complete <> "\n"

      expect(Mojentic.HTTPMock, :post_stream, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["name"] == model
        assert decoded["stream"] == true

        {:ok, [{:data, stream_data}]}
      end)

      assert {:ok, ^model} = Ollama.pull_model(model)
    end

    test "successfully pulls a model with progress callback" do
      model = "qwen2.5:3b"

      pull_status1 =
        Jason.encode!(%{
          "status" => "downloading",
          "completed" => 500,
          "total" => 1000,
          "digest" => "sha256:abc123"
        })

      pull_status2 =
        Jason.encode!(%{
          "status" => "downloading",
          "completed" => 1000,
          "total" => 1000,
          "digest" => "sha256:abc123"
        })

      pull_complete = Jason.encode!(%{"status" => "success"})
      stream_data = pull_status1 <> "\n" <> pull_status2 <> "\n" <> pull_complete <> "\n"

      test_pid = self()

      progress_callback = fn status ->
        send(test_pid, {:progress, status})
      end

      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:ok, [{:data, stream_data}]}
      end)

      assert {:ok, ^model} = Ollama.pull_model(model, progress_callback)

      assert_received {:progress, %{status: "downloading", completed: 500, total: 1000}}
      assert_received {:progress, %{status: "downloading", completed: 1000, total: 1000}}
      assert_received {:progress, %{status: "success"}}
    end

    test "handles request failures during pull" do
      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:error, :network_error}
      end)

      assert {:error, {:request_failed, :network_error}} = Ollama.pull_model("model")
    end

    test "handles incomplete JSON chunks during pull" do
      model = "test-model"

      # Split JSON across chunks to test buffering
      chunk1 = "{\"status\": \"down"
      chunk2 = "loading\"}\n{\"status\": \"success\"}\n"

      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:ok, [{:data, chunk1}, {:data, chunk2}]}
      end)

      assert {:ok, ^model} = Ollama.pull_model(model)
    end

    test "handles malformed JSON gracefully during pull" do
      model = "test-model"

      stream_data =
        "invalid json\n" <>
          Jason.encode!(%{"status" => "downloading"}) <>
          "\n" <> Jason.encode!(%{"status" => "success"}) <> "\n"

      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:ok, [{:data, stream_data}]}
      end)

      # Should continue despite malformed JSON
      assert {:ok, ^model} = Ollama.pull_model(model)
    end

    test "calls progress callback with all status fields" do
      model = "test-model"

      status_with_all_fields =
        Jason.encode!(%{
          "status" => "verifying",
          "completed" => 12_345,
          "total" => 54_321,
          "digest" => "sha256:def456"
        })

      stream_data =
        status_with_all_fields <> "\n" <> Jason.encode!(%{"status" => "success"}) <> "\n"

      test_pid = self()

      progress_callback = fn status ->
        send(test_pid, {:progress, status})
      end

      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:ok, [{:data, stream_data}]}
      end)

      assert {:ok, ^model} = Ollama.pull_model(model, progress_callback)

      assert_received {:progress,
                       %{
                         status: "verifying",
                         completed: 12_345,
                         total: 54_321,
                         digest: "sha256:def456"
                       }}

      assert_received {:progress, %{status: "success"}}
    end

    test "handles progress callback with partial fields" do
      model = "test-model"

      status_partial = Jason.encode!(%{"status" => "pulling manifest"})
      stream_data = status_partial <> "\n" <> Jason.encode!(%{"status" => "success"}) <> "\n"

      test_pid = self()

      progress_callback = fn status ->
        send(test_pid, {:progress, status})
      end

      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:ok, [{:data, stream_data}]}
      end)

      assert {:ok, ^model} = Ollama.pull_model(model, progress_callback)

      assert_received {:progress,
                       %{status: "pulling manifest", completed: nil, total: nil, digest: nil}}

      assert_received {:progress, %{status: "success"}}
    end
  end

  describe "tool integration" do
    defmodule MockTool do
      @behaviour Mojentic.LLM.Tools.Tool

      @impl true
      def run(_tool, _args), do: {:ok, %{result: "test"}}

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

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
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
      # Create temporary test image files
      image1_path = Path.join(System.tmp_dir!(), "test_image1.jpg")
      image2_path = Path.join(System.tmp_dir!(), "test_image2.jpg")
      File.write!(image1_path, "fake_image_data_1")
      File.write!(image2_path, "fake_image_data_2")

      # Expected base64 encodings
      expected_base64_1 = Base.encode64("fake_image_data_1")
      expected_base64_2 = Base.encode64("fake_image_data_2")

      messages = [
        Message.user("Describe this") |> Message.with_images([image1_path, image2_path])
      ]

      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        images = hd(decoded["messages"])["images"]
        assert images == [expected_base64_1, expected_base64_2]
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)

      # Clean up
      File.rm(image1_path)
      File.rm(image2_path)
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

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
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

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["options"]["num_predict"] == 200
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "omits num_predict when max_tokens is zero and num_predict is nil" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.5,
        max_tokens: 0,
        num_ctx: 1024,
        num_predict: nil
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded["options"], "num_predict")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "passes top_p parameter in options" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        num_predict: nil,
        top_p: 0.9
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["options"]["top_p"] == 0.9
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "passes top_k parameter in options" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        num_predict: nil,
        top_k: 40
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["options"]["top_k"] == 40
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "passes both top_p and top_k parameters" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        num_predict: nil,
        top_p: 0.95,
        top_k: 50
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["options"]["top_p"] == 0.95
        assert decoded["options"]["top_k"] == 50
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "omits top_p when nil" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.5,
        max_tokens: 50,
        num_ctx: 1024,
        num_predict: nil,
        top_p: nil
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded["options"], "top_p")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "omits top_k when nil" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.5,
        max_tokens: 50,
        num_ctx: 1024,
        num_predict: nil,
        top_k: nil
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded["options"], "top_k")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "passes response_format with json_object type and schema" do
      messages = [Message.user("Test")]
      schema = %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}}

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        response_format: %{type: :json_object, schema: schema}
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["format"] == schema
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "passes response_format with json_object type without schema" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        response_format: %{type: :json_object, schema: nil}
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["format"] == "json"
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "omits format when response_format is nil" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        response_format: nil
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "format")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "omits format when response_format type is text" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        response_format: %{type: :text, schema: nil}
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "format")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "includes think parameter when reasoning_effort is set" do
      messages = [Message.user("Think deeply about this")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        reasoning_effort: :high
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "After careful thought...",
            "role" => "assistant",
            "thinking" => "Let me analyze this problem step by step..."
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert decoded["think"] == true
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, %GatewayResponse{content: "After careful thought...", thinking: thinking}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)

      assert thinking == "Let me analyze this problem step by step..."
    end

    test "omits think parameter when reasoning_effort is nil" do
      messages = [Message.user("Test")]

      config = %CompletionConfig{
        temperature: 0.7,
        max_tokens: 100,
        num_ctx: 2048,
        reasoning_effort: nil
      }

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "think")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end
  end

  describe "complete_stream/4" do
    test "handles request failure during streaming" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      expect(Mojentic.HTTPMock, :post_stream, fn _url, _body, _headers, _opts ->
        {:error, :connection_refused}
      end)

      stream = Ollama.complete_stream("qwen2.5:3b", messages, [], config)

      results = Enum.to_list(stream)
      assert [{:error, :connection_refused}] = results
    end

    test "stream includes tools in request when provided" do
      defmodule MockStreamTool do
        @behaviour Mojentic.LLM.Tools.Tool

        @impl true
        def run(_args), do: {:ok, %{result: "test"}}

        @impl true
        def descriptor do
          %{
            type: "function",
            function: %{
              name: "mock_stream_tool",
              description: "A mock streaming tool",
              parameters: %{type: "object", properties: %{}}
            }
          }
        end

        def matches?("mock_stream_tool"), do: true
        def matches?(_), do: false
      end

      messages = [Message.user("Use a tool")]
      config = CompletionConfig.new()
      tools = [MockStreamTool]

      expect(Mojentic.HTTPMock, :post_stream, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        assert is_list(decoded["tools"])
        assert length(decoded["tools"]) == 1
        assert decoded["stream"] == true
        {:ok, []}
      end)

      stream = Ollama.complete_stream("qwen2.5:3b", messages, tools, config)
      _results = Enum.to_list(stream)
    end
  end

  describe "edge cases" do
    test "handles empty tool_calls in message" do
      messages = [%Message{role: :assistant, content: "test", tool_calls: []}]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        refute Map.has_key?(msg, "tool_calls")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles nil tool_calls in message" do
      messages = [%Message{role: :assistant, content: "test", tool_calls: nil}]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        refute Map.has_key?(msg, "tool_calls")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles empty image_paths in message" do
      messages = [%Message{role: :user, content: "test", image_paths: []}]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        refute Map.has_key?(msg, "images")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles nil image_paths in message" do
      messages = [%Message{role: :user, content: "test", image_paths: nil}]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        refute Map.has_key?(msg, "images")
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles file read error for images" do
      messages = [
        Message.user("Describe this") |> Message.with_images(["/nonexistent/path.jpg"])
      ]

      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        # Should have images key but empty list due to read error
        images = Map.get(msg, "images", [])
        assert images == []
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles response with nil content" do
      messages = [Message.user("Hello")]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, %GatewayResponse{content: nil, tool_calls: []}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles message with nil content" do
      messages = [%Message{role: :user, content: nil, tool_calls: nil, image_paths: nil}]
      config = CompletionConfig.new()

      response_body =
        Jason.encode!(%{
          "message" => %{
            "content" => "Response",
            "role" => "assistant"
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        msg = hd(decoded["messages"])
        assert msg["content"] == ""
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, _response} = Ollama.complete("qwen2.5:3b", messages, [], config)
    end

    test "handles tool_calls without arguments" do
      messages = [Message.user("Use tool")]
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
                  "name" => "test_tool"
                  # No arguments field
                }
              }
            ]
          }
        })

      expect(Mojentic.HTTPMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: response_body}}
      end)

      assert {:ok, %GatewayResponse{content: "", tool_calls: [tool_call]}} =
               Ollama.complete("qwen2.5:3b", messages, [], config)

      assert tool_call.arguments == %{}
    end
  end
end
