#!/usr/bin/env elixir

# Example: Broker as Tool - Multi-Agent Delegation Pattern
#
# This example demonstrates how to use ToolWrapper to wrap agents as tools,
# enabling a coordinator agent to delegate tasks to specialist agents.
#
# Run with: elixir examples/broker_as_tool.exs

Mix.install([
  {:mojentic, path: "./"}
])

alias Mojentic.Agents.BaseLLMAgent
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.DateResolver
alias Mojentic.LLM.Tools.ToolWrapper

# Create a temporal specialist agent
# This agent specializes in historical dates and temporal reasoning
temporal_specialist =
  BaseLLMAgent.new(
    broker: Broker.new("qwen3:7b", Ollama),
    behaviour: """
    You are a historian specializing in temporal reasoning and historical dates.
    You have deep knowledge of world history and can accurately determine dates
    of historical events. Use your tools to resolve relative dates like "tomorrow"
    or "next week" when needed.
    """,
    tools: [DateResolver]
  )

IO.puts("Created temporal specialist agent")

# Wrap the specialist as a tool
temporal_tool =
  ToolWrapper.new(
    agent: temporal_specialist,
    name: "temporal_specialist",
    description: """
    A historian specializing in temporal reasoning. Consult this specialist
    for questions about historical dates, timelines, and temporal calculations.
    Provide your question as the input parameter.
    """
  )

IO.puts("Wrapped specialist as a tool")

# Create a coordinator agent that uses the specialist
coordinator =
  BaseLLMAgent.new(
    broker: Broker.new("qwen3:32b", Ollama),
    behaviour: """
    You are a coordinator agent that delegates specialized questions to expert agents.
    When you receive a question about history or dates, use the temporal_specialist tool.
    Always provide a complete and informative response based on the specialist's answer.
    """,
    tools: [temporal_tool]
  )

IO.puts("Created coordinator agent")
IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("MULTI-AGENT DELEGATION EXAMPLE")
IO.puts(String.duplicate("=", 80) <> "\n")

# Example queries
queries = [
  "When was the Roman Empire founded?",
  "What year did the American Revolution begin?",
  "How long ago was World War II?"
]

Enum.each(queries, fn query ->
  IO.puts("Query: #{query}")
  IO.puts("Processing...\n")

  case BaseLLMAgent.generate_response(coordinator, query) do
    {:ok, response} ->
      IO.puts("Response: #{response}")

    {:error, reason} ->
      IO.puts("Error: #{inspect(reason)}")
  end

  IO.puts("\n" <> String.duplicate("-", 80) <> "\n")
end)

IO.puts("Example complete!")
