#!/usr/bin/env elixir

# Streaming Example - Demonstrates streaming text generation with tool calling
#
# This example shows how generate_stream/4 handles tool calls seamlessly:
# 1. Streams content as it arrives
# 2. Detects tool calls in the stream
# 3. Executes tools
# 4. Recursively streams the LLM's response after tool execution
#
# Run with: mix run examples/streaming.exs

defmodule CalculatorTool do
  @behaviour Mojentic.LLM.Tools.Tool

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "calculate",
        description: "Perform basic arithmetic calculations",
        parameters: %{
          type: "object",
          properties: %{
            expression: %{
              type: "string",
              description: "The mathematical expression to evaluate (e.g., '2 + 2', '10 * 5')"
            }
          },
          required: ["expression"]
        }
      }
    }
  end

  @impl true
  def run(%{"expression" => expression}) do
    try do
      # Simple arithmetic parser for basic operations
      result =
        expression
        |> String.replace(" ", "")
        |> evaluate()

      {:ok, %{expression: expression, result: result}}
    rescue
      _ -> {:error, "Unable to evaluate expression: #{expression}"}
    end
  end

  def run(_), do: {:error, "Missing expression parameter"}

  defp evaluate(expr) do
    # Simple evaluator that handles left-to-right evaluation
    # Split by operators while keeping them
    tokens =
      Regex.scan(~r/\d+|[+\-\*\/]/, expr)
      |> List.flatten()

    # Start with first number
    [first | rest] = tokens
    acc = String.to_integer(first)

    # Process operator-number pairs
    rest
    |> Enum.chunk_every(2)
    |> Enum.reduce(acc, fn
      [op, num], acc ->
        n = String.to_integer(num)

        case op do
          "+" -> acc + n
          "-" -> acc - n
          "*" -> acc * n
          "/" -> div(acc, n)
        end
    end)
  end
end

defmodule StreamingExample do
  alias Mojentic.LLM.{Broker, Message}
  alias Mojentic.LLM.Gateways.Ollama

  def main do
    # Create broker with Ollama
    broker = Broker.new("qwen3:32b", Ollama)

    IO.puts("Streaming response with tool calling enabled...\n")

    # Ask a question that requires calculation
    messages = [
      Message.user(
        "If I have 15 apples and I give away 7, then buy 12 more, how many apples do I have? " <>
          "Please use the calculate tool to work this out step by step."
      )
    ]

    broker
    |> Broker.generate_stream(messages, [CalculatorTool])
    |> Stream.each(&IO.write/1)
    |> Stream.run()

    IO.puts("\n\nDone!")
  end
end

StreamingExample.main()
