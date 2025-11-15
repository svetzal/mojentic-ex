#!/usr/bin/env elixir

# Example demonstrating the CurrentDatetime tool
# This tool allows the LLM to get the current date and time

Mix.install([
  {:mojentic, path: ".."}
])

alias Mojentic.LLM.Broker
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Message
alias Mojentic.LLM.Tools.CurrentDatetime

IO.puts("🚀 Mojentic Elixir - Current Datetime Tool Example\n")

# Initialize the gateway and broker
gateway = Ollama.new()
broker = Broker.new("qwen3:32b", gateway)

IO.puts("Using model: #{broker.model}\n")

# Create the tool
tool = CurrentDatetime.new()

IO.puts("Available tool:")
descriptor = tool.descriptor()
IO.puts("  - #{descriptor.function.name}: #{descriptor.function.description}")
IO.puts("")

# Example 1: Ask for current time
IO.puts("Example 1: What time is it right now?\n")

messages = [
  Message.system("You are a helpful assistant with access to tools."),
  Message.user("What time is it right now? Also, what day of the week is it today?")
]

case Broker.generate(broker, messages, [tool]) do
  {:ok, response} ->
    IO.puts("LLM Response:")
    IO.puts(response)
    IO.puts("")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}\n")
end

# Example 2: Ask for current date in a friendly format
IO.puts("Example 2: What's today's date in a friendly format?\n")

messages = [
  Message.system("You are a helpful assistant with access to tools."),
  Message.user("Tell me the current date in a friendly format, like 'Monday, January 1, 2023'")
]

case Broker.generate(broker, messages, [tool]) do
  {:ok, response} ->
    IO.puts("LLM Response:")
    IO.puts(response)
    IO.puts("")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}\n")
end

# Example 3: Multiple queries about time
IO.puts("Example 3: When was this program run?\n")

messages = [
  Message.system("You are a helpful assistant with access to tools."),
  Message.user("When was this program run? Give me the exact timestamp.")
]

case Broker.generate(broker, messages, [tool]) do
  {:ok, response} ->
    IO.puts("LLM Response:")
    IO.puts(response)
    IO.puts("")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}\n")
end

IO.puts("✅ Example completed!")
