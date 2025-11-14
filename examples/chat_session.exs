#!/usr/bin/env elixir

# Basic chat session example
#
# This example demonstrates a simple interactive chat session with an LLM.
# The session maintains conversation history automatically.
#
# Usage:
#   mix run examples/chat_session.exs
#
# Type your queries and press Enter. Type an empty line to exit.

alias Mojentic.LLM.Broker
alias Mojentic.LLM.ChatSession
alias Mojentic.LLM.Gateways.Ollama

defmodule ChatLoop do
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

IO.puts("Starting chat session with qwen3:32b...")
IO.puts("Type your query and press Enter. Empty line to exit.\n")

broker = Broker.new("qwen3:32b", Ollama)
session = ChatSession.new(broker)

ChatLoop.run(session)
