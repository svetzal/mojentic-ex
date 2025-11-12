#!/usr/bin/env elixir

# List available models from Ollama gateway
#
# Usage:
#   mix run examples/list_models.exs
#
# Requirements:
#   - Ollama running locally (default: http://localhost:11434)
#   - At least one model pulled (e.g., ollama pull qwen3:32b)

alias Mojentic.LLM.Gateways.Ollama

IO.puts("Ollama Models:")

case Ollama.get_available_models() do
  {:ok, models} ->
    Enum.each(models, fn model ->
      IO.puts("- #{model}")
    end)

  {:error, reason} ->
    IO.puts("Error fetching models: #{inspect(reason)}")
    IO.puts("\nMake sure Ollama is running:")
    IO.puts("  ollama serve")
    IO.puts("\nAnd that you have at least one model pulled:")
    IO.puts("  ollama pull qwen3:32b")
end
