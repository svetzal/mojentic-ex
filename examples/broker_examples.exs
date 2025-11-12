#!/usr/bin/env elixir

# Comprehensive broker feature tests
#
# This example demonstrates all major broker capabilities:
# - Simple text generation
# - Structured output with schemas
# - Tool usage
# - Image analysis (multimodal)
#
# Usage:
#   mix run examples/broker_examples.exs
#
# Requirements:
#   - Ollama running locally (default: http://localhost:11434)
#   - Models pulled:
#     - qwen3:32b (for text, structured, tools)
#     - qwen3-vl:30b (for image analysis)

alias Mojentic.LLM.Broker
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Message
alias Mojentic.LLM.Tools.DateResolver

# Helper function to print section headers
print_section = fn title ->
  IO.puts("\n" <> String.duplicate("=", 60))
  IO.puts("  #{title}")
  IO.puts(String.duplicate("=", 60) <> "\n")
end

# Helper function to print test results
print_result = fn test_name, result ->
  IO.puts("#{test_name}:")
  case result do
    {:ok, content} when is_binary(content) ->
      IO.puts("✅ Success: #{content}\n")
    {:ok, data} ->
      IO.puts("✅ Success: #{inspect(data, pretty: true)}\n")
    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}\n")
  end
end

# Initialize brokers for different models
text_broker = Broker.new("qwen3:32b", Ollama)
vision_broker = Broker.new("qwen3-vl:30b", Ollama)

# ============================================================================
# Test 1: Simple Text Generation
# ============================================================================
print_section.("Test 1: Simple Text Generation")

IO.puts("Testing with model: qwen3:32b")
messages = [Message.user("Hello, how are you?")]

case Broker.generate(text_broker, messages) do
  {:ok, response} ->
    print_result.("Simple text generation", {:ok, response})
  {:error, reason} ->
    print_result.("Simple text generation", {:error, reason})
end

# ============================================================================
# Test 2: Structured Output
# ============================================================================
print_section.("Test 2: Structured Output")

IO.puts("Testing structured output with schema...")

# Define a schema for sentiment analysis
schema = %{
  type: "object",
  properties: %{
    label: %{
      type: "string",
      description: "label for the sentiment (positive, negative, neutral)"
    },
    confidence: %{
      type: "number",
      description: "confidence score between 0 and 1"
    }
  },
  required: ["label", "confidence"]
}

messages = [Message.user("I love this product! It's amazing and works perfectly.")]

case Broker.generate_object(text_broker, messages, schema) do
  {:ok, result} ->
    print_result.("Structured output", {:ok, result})
  {:error, reason} ->
    print_result.("Structured output", {:error, reason})
end

# ============================================================================
# Test 3: Tool Usage
# ============================================================================
print_section.("Test 3: Tool Usage")

IO.puts("Testing tool usage with DateResolver...")

messages = [Message.user("What day of the week is Christmas 2025?")]

case Broker.generate(text_broker, messages, [DateResolver]) do
  {:ok, response} ->
    print_result.("Tool usage", {:ok, response})
  {:error, reason} ->
    print_result.("Tool usage", {:error, reason})
end

# ============================================================================
# Test 4: Image Analysis (Multimodal)
# ============================================================================
print_section.("Test 4: Image Analysis (Multimodal)")

image_path = Path.join([__DIR__, "images", "flash_rom.jpg"])

if File.exists?(image_path) do
  IO.puts("Testing image analysis with model: qwen3-vl:30b")
  IO.puts("Image path: #{image_path}")

  messages = [
    Message.user("What text is visible in this image? Please extract all readable text.")
    |> Message.with_images([image_path])
  ]

  case Broker.generate(vision_broker, messages) do
    {:ok, response} ->
      print_result.("Image analysis", {:ok, response})
    {:error, reason} ->
      print_result.("Image analysis", {:error, reason})
  end
else
  IO.puts("❌ Image file not found: #{image_path}")
  IO.puts("Skipping image analysis test.\n")
end

# ============================================================================
# Summary
# ============================================================================
print_section.("Summary")

IO.puts("""
All broker feature tests completed!

Features demonstrated:
✓ Simple text generation
✓ Structured output with JSON schema
✓ Tool calling with DateResolver
✓ Multimodal image analysis

For more detailed examples, see:
- examples/simple_llm.exs
- examples/structured_output.exs
- examples/tool_usage.exs
- examples/image_analysis.exs
""")
