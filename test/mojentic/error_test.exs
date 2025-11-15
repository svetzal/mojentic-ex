defmodule Mojentic.ErrorTest do
  use ExUnit.Case, async: true

  alias Mojentic.Error

  doctest Mojentic.Error

  describe "gateway_error/1" do
    test "creates a gateway error tuple with string message" do
      assert {:error, {:gateway_error, "Connection failed"}} =
               Error.gateway_error("Connection failed")
    end
  end

  describe "api_error/1" do
    test "creates an API error tuple with string message" do
      assert {:error, {:api_error, "Rate limit exceeded"}} =
               Error.api_error("Rate limit exceeded")
    end
  end

  describe "http_error/1" do
    test "creates an HTTP error tuple with status code" do
      assert {:error, {:http_error, 404}} = Error.http_error(404)
      assert {:error, {:http_error, 500}} = Error.http_error(500)
      assert {:error, {:http_error, 200}} = Error.http_error(200)
    end
  end

  describe "request_failed/1" do
    test "creates a request failed error with atom reason" do
      assert {:error, {:request_failed, :timeout}} = Error.request_failed(:timeout)
    end

    test "creates a request failed error with complex term" do
      assert {:error, {:request_failed, {:ssl_error, "certificate verify failed"}}} =
               Error.request_failed({:ssl_error, "certificate verify failed"})
    end

    test "creates a request failed error with any term" do
      assert {:error, {:request_failed, %{error: "custom"}}} =
               Error.request_failed(%{error: "custom"})
    end
  end

  describe "tool_error/1" do
    test "creates a tool error tuple with string message" do
      assert {:error, {:tool_error, "Invalid parameters"}} =
               Error.tool_error("Invalid parameters")
    end
  end

  describe "config_error/1" do
    test "creates a config error tuple with string message" do
      assert {:error, {:config_error, "Missing API key"}} =
               Error.config_error("Missing API key")
    end
  end

  describe "serialization_error/1" do
    test "creates a serialization error tuple with string message" do
      assert {:error, {:serialization_error, "Invalid JSON"}} =
               Error.serialization_error("Invalid JSON")
    end
  end

  describe "invalid_response/0" do
    test "creates an invalid response error tuple" do
      assert {:error, :invalid_response} = Error.invalid_response()
    end
  end

  describe "model_not_supported/0" do
    test "creates a model not supported error tuple" do
      assert {:error, :model_not_supported} = Error.model_not_supported()
    end
  end

  describe "timeout/0" do
    test "creates a timeout error tuple" do
      assert {:error, :timeout} = Error.timeout()
    end
  end

  describe "format_error/1" do
    test "formats gateway error" do
      assert "Gateway error: Connection failed" =
               Error.format_error({:gateway_error, "Connection failed"})
    end

    test "formats API error" do
      assert "API error: Rate limit exceeded" =
               Error.format_error({:api_error, "Rate limit exceeded"})
    end

    test "formats HTTP error with status code" do
      assert "HTTP error: 404" = Error.format_error({:http_error, 404})
      assert "HTTP error: 500" = Error.format_error({:http_error, 500})
    end

    test "formats request failed error with atom" do
      assert "Request failed: :timeout" = Error.format_error({:request_failed, :timeout})
    end

    test "formats request failed error with complex term" do
      result = Error.format_error({:request_failed, {:ssl_error, "certificate verify failed"}})
      assert String.starts_with?(result, "Request failed:")
      assert String.contains?(result, "ssl_error")
    end

    test "formats tool error" do
      assert "Tool error: Invalid parameters" =
               Error.format_error({:tool_error, "Invalid parameters"})
    end

    test "formats config error" do
      assert "Configuration error: Missing API key" =
               Error.format_error({:config_error, "Missing API key"})
    end

    test "formats serialization error" do
      assert "Serialization error: Invalid JSON" =
               Error.format_error({:serialization_error, "Invalid JSON"})
    end

    test "formats invalid response error" do
      assert "Invalid response" = Error.format_error(:invalid_response)
    end

    test "formats model not supported error" do
      assert "Model not supported" = Error.format_error(:model_not_supported)
    end

    test "formats timeout error" do
      assert "Timeout" = Error.format_error(:timeout)
    end

    test "formats plain string error" do
      assert "Custom error message" = Error.format_error("Custom error message")
    end

    test "formats unknown error types" do
      result = Error.format_error({:unknown_error, "something"})
      assert String.starts_with?(result, "Unknown error:")
      assert String.contains?(result, "unknown_error")
    end

    test "formats unexpected atom" do
      result = Error.format_error(:unexpected_atom)
      assert String.starts_with?(result, "Unknown error:")
      assert String.contains?(result, "unexpected_atom")
    end

    test "formats nil gracefully" do
      result = Error.format_error(nil)
      assert String.starts_with?(result, "Unknown error:")
    end

    test "formats integer gracefully" do
      result = Error.format_error(42)
      assert String.starts_with?(result, "Unknown error:")
      assert String.contains?(result, "42")
    end
  end
end
