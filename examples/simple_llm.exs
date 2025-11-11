# Simple LLM Example
#
# This example demonstrates basic text generation using Mojentic
# with a local Ollama model.
#
# Usage:
#   mix run examples/simple_llm.exs

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

# Create Ollama gateway and broker
broker = Broker.new("phi4:14b", Ollama)

# Create a simple message
messages = [
  Message.user("Explain what Elixir is in one sentence.")
]

# Generate a response
IO.puts("Generating response...")
IO.puts("")

case Broker.generate(broker, messages) do
  {:ok, response} ->
    IO.puts("Response: #{response}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
