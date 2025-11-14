#!/usr/bin/env elixir

# Example demonstrating the Ollama Gateway embeddings usage.
#
# This shows how to:
# - Generate embeddings for text using Ollama
# - Display embedding dimensions
# - Use the mxbai-embed-large model
#
# Prerequisites:
# - Ollama must be running: `ollama serve`
# - The mxbai-embed-large model must be available
#   Pull it with: `ollama pull mxbai-embed-large`
#
# Run with: mix run examples/embeddings.exs

alias Mojentic.LLM.Gateways.Ollama

defmodule EmbeddingsExample do
  def run do
    IO.puts("=== Ollama Embeddings Example ===\n")

    # Text to embed
    text = "Hello, world!"
    model = "mxbai-embed-large"

    IO.puts("Text: \"#{text}\"")
    IO.puts("Model: #{model}\n")

    # Calculate embeddings using the Ollama gateway
    case Ollama.calculate_embeddings(text, model) do
      {:ok, embedding} ->
        IO.puts("Embedding dimensions: #{length(embedding)}")
        IO.puts("First 5 values: #{inspect(Enum.take(embedding, 5))}")
        IO.puts("\nEmbedding generated successfully!")

      {:error, {:http_error, 404}} ->
        IO.puts("Error: Model not found. Please pull it first:")
        IO.puts("  ollama pull #{model}")

      {:error, {:request_failed, %HTTPoison.Error{reason: :econnrefused}}} ->
        IO.puts("Error: Cannot connect to Ollama. Please ensure it's running:")
        IO.puts("  ollama serve")

      {:error, reason} ->
        IO.puts("Error generating embeddings: #{inspect(reason)}")
    end
  end
end

EmbeddingsExample.run()
