#!/usr/bin/env elixir

# Image Analysis Example
#
# This example demonstrates multimodal capabilities - analyzing images
# with vision-capable LLM models.
#
# Usage:
#   mix run examples/image_analysis.exs
#
# Requirements:
#   - Ollama running locally (default: http://localhost:11434)
#   - A vision-capable model pulled (e.g., ollama pull llava:latest)
#   - Test image at examples/images/flash_rom.jpg

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

# Get the absolute path to the image
image_path = Path.expand("images/flash_rom.jpg", __DIR__)

# Check if image exists
unless File.exists?(image_path) do
  IO.puts("Error: Image not found at #{image_path}")
  IO.puts("\nMake sure the test image exists:")
  IO.puts("  examples/images/flash_rom.jpg")
  System.halt(1)
end

IO.puts("Analyzing image with vision model...")
IO.puts("Image: #{image_path}")
IO.puts("")

# Create a broker with a vision-capable model
# Options: llava:latest, bakllava:latest, gemma3:27b, qwen3-vl:30b, etc.
broker = Broker.new("qwen3-vl:30b", Ollama)

# Create a message with image
message =
  Message.user("This is a Flash ROM chip on an adapter board. Extract the text on top of the chip.")
  |> Message.with_images([image_path])

# Generate response
case Broker.generate(broker, [message]) do
  {:ok, response} ->
    IO.puts("Response:")
    IO.puts(response)

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
    IO.puts("")
    IO.puts("Make sure you have a vision-capable model installed:")
    IO.puts("  ollama pull gemma3:27b")
    IO.puts("")
    IO.puts("Other vision models to try:")
    IO.puts("  ollama pull llava:latest")
    IO.puts("  ollama pull bakllava:latest")
    IO.puts("  ollama pull qwen3-vl:30b")
end
