#!/usr/bin/env elixir

# Pull a model from Ollama with progress tracking
#
# Usage:
#   mix run examples/pull_model.exs [model_name]
#
# Example:
#   mix run examples/pull_model.exs qwen2.5:3b
#
# Requirements:
#   - Ollama running locally (default: http://localhost:11434)
#
# This example demonstrates how to:
# 1. Pull a model from the Ollama library
# 2. Track download progress with a callback function
# 3. Display progress information to the user

alias Mojentic.LLM.Gateways.Ollama

# Get model name from command line args or use default
model =
  case System.argv() do
    [model_name | _] -> model_name
    [] -> "qwen2.5:3b"
  end

IO.puts("Pulling model: #{model}")
IO.puts("This may take a while depending on the model size and your connection speed.\n")

# Define a progress callback that displays download status
progress_callback = fn status ->
  case status do
    %{status: "pulling manifest"} ->
      IO.write("\r\e[K")
      IO.write("📋 Pulling manifest...")

    %{status: "downloading", completed: completed, total: total, digest: digest}
    when not is_nil(completed) and not is_nil(total) and total > 0 ->
      percentage = Float.round(completed / total * 100, 1)
      completed_mb = Float.round(completed / 1_024 / 1024, 2)
      total_mb = Float.round(total / 1_024 / 1024, 2)
      digest_short = String.slice(digest || "", 7, 12)

      IO.write("\r\e[K")

      IO.write(
        "⬇️  Downloading [#{digest_short}]: #{percentage}% (#{completed_mb} / #{total_mb} MB)"
      )

    %{status: "downloading", digest: digest} when not is_nil(digest) ->
      digest_short = String.slice(digest, 7, 12)
      IO.write("\r\e[K")
      IO.write("⬇️  Downloading [#{digest_short}]...")

    %{status: "downloading"} ->
      IO.write("\r\e[K")
      IO.write("⬇️  Downloading...")

    %{status: "verifying", digest: digest} when not is_nil(digest) ->
      digest_short = String.slice(digest, 7, 12)
      IO.write("\r\e[K")
      IO.write("✓ Verifying [#{digest_short}]...")

    %{status: "verifying"} ->
      IO.write("\r\e[K")
      IO.write("✓ Verifying checksums...")

    %{status: "writing manifest"} ->
      IO.write("\r\e[K")
      IO.write("📝 Writing manifest...")

    %{status: "success"} ->
      IO.write("\r\e[K")
      IO.puts("✅ Success!")

    %{status: status_str} ->
      IO.write("\r\e[K")
      IO.write("ℹ️  #{status_str}...")

    other ->
      IO.write("\r\e[K")
      IO.write("Processing: #{inspect(other)}")
  end

  # Flush output immediately
  IO.write("")
end

# Pull the model with progress tracking
case Ollama.pull_model(model, progress_callback) do
  {:ok, ^model} ->
    IO.puts("\n\n🎉 Model '#{model}' successfully pulled!")
    IO.puts("\nYou can now use it in your applications:")
    IO.puts("  alias Mojentic.LLM.{Broker, Message}")
    IO.puts("  alias Mojentic.LLM.Gateways.Ollama")
    IO.puts("")
    IO.puts("  broker = Broker.new(\"#{model}\", Ollama)")
    IO.puts("  messages = [Message.user(\"Hello!\")]")
    IO.puts("  {:ok, response} = Broker.generate(broker, messages)")

  {:error, {:http_error, 404}} ->
    IO.puts("\n\n❌ Error: Model '#{model}' not found in the Ollama library.")
    IO.puts("\nCheck available models at: https://ollama.ai/library")
    IO.puts("Make sure the model name and tag are correct.")
    System.halt(1)

  {:error, {:request_failed, :econnrefused}} ->
    IO.puts("\n\n❌ Error: Cannot connect to Ollama service.")
    IO.puts("\nMake sure Ollama is running:")
    IO.puts("  ollama serve")
    System.halt(1)

  {:error, :timeout} ->
    IO.puts("\n\n❌ Error: Request timed out.")
    IO.puts("\nThe model download is taking longer than expected.")
    IO.puts("You might want to:")
    IO.puts("  1. Check your internet connection")
    IO.puts("  2. Try pulling the model directly: ollama pull #{model}")
    IO.puts("  3. Increase OLLAMA_TIMEOUT environment variable")
    System.halt(1)

  {:error, reason} ->
    IO.puts("\n\n❌ Error pulling model: #{inspect(reason)}")
    System.halt(1)
end
