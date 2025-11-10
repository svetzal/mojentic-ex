# Tool Usage Example
#
# This example demonstrates how to use tools with an LLM,
# allowing it to call functions to get information or perform actions.
#
# Usage:
#   mix run examples/tool_usage.exs

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.Tool

# Define a weather tool (mocked)
defmodule WeatherTool do
  @behaviour Tool

  @impl Tool
  def run(arguments) do
    location = Map.get(arguments, "location", "unknown")

    # In a real implementation, you would call a weather API here
    {:ok,
     %{
       location: location,
       temperature: 22,
       condition: "sunny",
       humidity: 60
     }}
  end

  @impl Tool
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get the current weather for a location",
        parameters: %{
          type: "object",
          properties: %{
            location: %{
              type: "string",
              description: "The city or location to get weather for"
            }
          },
          required: ["location"]
        }
      }
    }
  end
end

# Create Ollama gateway and broker
broker = Broker.new("qwen3:32b", Ollama)

# Create tools list
tools = [WeatherTool]

# Create a message that should trigger tool use
messages = [
  Message.user("What's the weather like in San Francisco?")
]

# Generate a response (the LLM should call the tool)
IO.puts("Asking about weather (this will use the tool)...")
IO.puts("")

case Broker.generate(broker, messages, tools) do
  {:ok, response} ->
    IO.puts("Response: #{response}")

  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
