defmodule Mojentic.Examples.React.SummarizationAgent do
  @moduledoc """
  Summarization agent for the ReAct pattern.

  This agent generates the final answer based on accumulated context,
  synthesizing all the information gathered during the ReAct loop.
  """

  alias Mojentic.Examples.React.Events.{FailureOccurred, FinishAndSummarize}
  alias Mojentic.Examples.React.Formatters
  alias Mojentic.LLM.{Broker, Message}

  require Logger

  @doc """
  Receives and processes a FinishAndSummarize event.

  Generates a final answer based on the complete context history.

  ## Parameters

  - `broker`: LLM broker for generating the final summary
  - `event`: FinishAndSummarize event containing complete context

  ## Returns

  - `{:ok, []}` - Terminal event (stops the loop)
  - `{:ok, [FailureOccurred.t()]}` on error
  """
  def receive_event_async(%Broker{} = broker, %FinishAndSummarize{} = event) do
    try do
      prompt = build_prompt(event)
      IO.puts("\n#{format_block(prompt)}")

      case Broker.generate(broker, [Message.user(prompt)]) do
        {:ok, response} ->
          IO.puts("\n#{format_border()}")
          IO.puts("FINAL ANSWER:")
          IO.puts("#{format_border()}")
          IO.puts(response)
          IO.puts("#{format_border()}\n")

          # This is a terminal event - return empty list to stop the loop
          {:ok, []}

        {:error, reason} ->
          failure_event = %FailureOccurred{
            source: __MODULE__,
            context: event.context,
            reason: "Error during summarization: #{inspect(reason)}",
            correlation_id: event.correlation_id
          }

          {:ok, [failure_event]}
      end
    rescue
      e ->
        failure_event = %FailureOccurred{
          source: __MODULE__,
          context: event.context,
          reason: "Exception during summarization: #{Exception.message(e)}",
          correlation_id: event.correlation_id
        }

        {:ok, [failure_event]}
    end
  end

  def receive_event_async(_broker, _event), do: {:ok, []}

  defp build_prompt(event) do
    """
    Based on the following context, provide a clear and concise answer to the user's query.

    #{Formatters.format_current_context(event.context)}

    Your task:
    Review what we've learned and provide a direct answer to: "#{event.context.user_query}"

    Be specific and use the information gathered during our process.
    """
    |> String.trim()
  end

  defp format_block(content) do
    width = 80
    border = String.duplicate("=", width)
    "\n#{border}\n#{content}\n#{border}\n"
  end

  defp format_border do
    String.duplicate("=", 80)
  end
end
