# Structured Output Example
#
# This example demonstrates how to use JSON schemas to get
# structured output from an LLM, ensuring type-safe responses.
#
# Usage:
#   mix run examples/structured_output.exs

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

# Create Ollama gateway and broker
broker = Broker.new("qwen3:32b", Ollama)

# Define a JSON schema for sentiment analysis
schema = %{
  type: "object",
  properties: %{
    label: %{
      type: "string",
      description: "The sentiment label (positive, negative, or neutral)"
    },
    confidence: %{
      type: "number",
      description: "Confidence score between 0 and 1"
    },
    reasoning: %{
      type: "string",
      description: "Brief explanation of the sentiment analysis"
    }
  },
  required: ["label", "confidence", "reasoning"]
}

# Create a message asking for sentiment analysis
messages = [
  Message.user(
    "Analyze the sentiment of this text: 'I absolutely love this product! It exceeded all my expectations.'"
  )
]

# Generate a structured response
IO.puts("Generating structured sentiment analysis...")
IO.puts("")

case Broker.generate_object(broker, messages, schema) do
  {:ok, sentiment} ->
    IO.puts("Sentiment Analysis:")
    IO.puts("  Label: #{sentiment["label"]}")
    IO.puts("  Confidence: #{Float.round(sentiment["confidence"], 2)}")
    IO.puts("  Reasoning: #{sentiment["reasoning"]}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
