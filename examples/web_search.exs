#!/usr/bin/env elixir

# Example: Web Search Tool
#
# This example demonstrates using the WebSearchTool to search
# the web using DuckDuckGo's lite endpoint.
#
# Usage:
#   mix run examples/web_search.exs

Mix.install([{:mojentic, path: "."}])

alias Mojentic.LLM.Tools.WebSearchTool

IO.puts("Web Search Tool Example")
IO.puts("=======================\n")

# Create the tool
tool = WebSearchTool.new()

# Example 1: Basic search
IO.puts("Example 1: Searching for 'Elixir programming language'")
IO.puts("-------------------------------------------------------")

case WebSearchTool.run(tool, %{"query" => "Elixir programming language"}) do
  {:ok, results} ->
    IO.puts("Found #{length(results)} results:\n")

    results
    |> Enum.take(5)
    |> Enum.with_index(1)
    |> Enum.each(fn {result, index} ->
      IO.puts("#{index}. #{result.title}")
      IO.puts("   URL: #{result.url}")
      IO.puts("   Snippet: #{result.snippet}\n")
    end)

  {:error, reason} ->
    IO.puts("Search failed: #{reason}")
end

IO.puts("\n")

# Example 2: Search with special characters
IO.puts("Example 2: Searching for 'functional programming & BEAM'")
IO.puts("---------------------------------------------------------")

case WebSearchTool.run(tool, %{"query" => "functional programming & BEAM"}) do
  {:ok, results} ->
    IO.puts("Found #{length(results)} results:\n")

    results
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.each(fn {result, index} ->
      IO.puts("#{index}. #{result.title}")
      IO.puts("   URL: #{result.url}\n")
    end)

  {:error, reason} ->
    IO.puts("Search failed: #{reason}")
end

IO.puts("\n")

# Example 3: Tool descriptor (for LLM integration)
IO.puts("Example 3: Tool Descriptor for LLM")
IO.puts("-----------------------------------")

descriptor = WebSearchTool.descriptor()
IO.puts("Tool Name: #{descriptor.function.name}")
IO.puts("Description: #{descriptor.function.description}")
IO.puts("\nParameters:")
IO.inspect(descriptor.function.parameters, pretty: true)

IO.puts("\n")
IO.puts("Example 4: Error Handling")
IO.puts("-------------------------")

case WebSearchTool.run(tool, %{}) do
  {:ok, _results} ->
    IO.puts("Unexpected success")

  {:error, reason} ->
    IO.puts("Expected error: #{reason}")
end

IO.puts("\n✓ Examples completed!")
