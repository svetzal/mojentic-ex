# Tell User Tool Example
#
# This example demonstrates how to use the TellUser tool to display
# intermediate messages to the user without expecting a response.

alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.TellUser

# Create gateway and broker
{:ok, gateway} = Ollama.new()
broker = Broker.new("qwen3:32b", gateway)

# Create the TellUser tool
tell_user_tool = TellUser.new()

# User request
user_request = "Tell me about the benefits of exercise."

# Create messages with a system prompt encouraging tool usage
messages = [
  Message.system(
    "You are a helpful assistant. Use the tell_user tool to share important intermediate information with the user as you work on their request."
  ),
  Message.user(user_request)
]

# Generate response with the TellUser tool
IO.puts("User Request:")
IO.puts(user_request)
IO.puts("\nProcessing...\n")

case Broker.generate(broker, messages, tools: [tell_user_tool]) do
  {:ok, response} ->
    IO.puts("\nFinal Response:")
    IO.puts(response.content)

  {:error, error} ->
    IO.puts("\nError: #{inspect(error)}")
end
