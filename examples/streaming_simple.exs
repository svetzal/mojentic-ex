#!/usr/bin/env elixir

# Simple Streaming Example - Demonstrates basic streaming text generation
#
# This example shows how generate_stream/4 works without tools:
# 1. Streams content as it arrives
# 2. Prints each chunk immediately
#
# Run with: mix run examples/streaming_simple.exs

defmodule SimpleStreamingExample do
  alias Mojentic.LLM.{Broker, Message}
  alias Mojentic.LLM.Gateways.Ollama

  def main do
    # Create broker with Ollama
    broker = Broker.new("qwen3:32b", Ollama)

    IO.puts("Streaming response...\n")

    # Stream a simple story
    messages = [
      Message.user("Tell me a very short story about a dragon in three sentences.")
    ]

    broker
    |> Broker.generate_stream(messages)
    |> Stream.each(&IO.write/1)
    |> Stream.run()

    IO.puts("\n\nDone!")
  end
end

SimpleStreamingExample.main()
