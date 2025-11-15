#!/usr/bin/env elixir

# Chat session with tool example
#
# This example demonstrates a chat session with tool support.
# The LLM can use the DateResolver tool to calculate dates.
#
# Usage:
#   mix run examples/chat_session_with_tool.exs
#
# Try queries like:
#   - "What day is tomorrow?"
#   - "What was the date 5 days ago?"
#   - "What will be the date in 2 weeks?"

alias Mojentic.LLM.Broker
alias Mojentic.LLM.ChatSession
alias Mojentic.LLM.Gateways.Ollama
alias Mojentic.LLM.Tools.DateResolver

defmodule ChatLoopWithTools do
  def run(session) do
    query = IO.gets("Query: ") |> String.trim()

    if query == "" do
      IO.puts("\nGoodbye!")
    else
      case ChatSession.send(session, query) do
        {:ok, response, updated_session} ->
          IO.puts(response)
          IO.puts("")
          run(updated_session)

        {:error, reason} ->
          IO.puts("Error: #{inspect(reason)}")
          IO.puts("")
          run(session)
      end
    end
  end
end

IO.puts("Starting chat session with qwen3:32b and DateResolver tool...")
IO.puts("Try asking about dates (e.g., 'What day is tomorrow?')")
IO.puts("Type your query and press Enter. Empty line to exit.\n")

broker = Broker.new("qwen3:32b", Ollama)
session = ChatSession.new(broker, tools: [DateResolver.new()])

ChatLoopWithTools.run(session)
