defmodule Mojentic.Examples.React.ThinkingAgent do
  @moduledoc """
  Planning agent for the ReAct pattern.

  This agent creates structured plans for solving user queries using
  an LLM to analyze the problem and break it into actionable steps.
  """

  alias Mojentic.Examples.React.Events.{FailureOccurred, InvokeDecisioning, InvokeThinking}
  alias Mojentic.Examples.React.Formatters
  alias Mojentic.Examples.React.Models.{Plan, ThoughtActionObservation}
  alias Mojentic.LLM.{Broker, Message}
  alias Mojentic.LLM.Tools.DateResolver

  require Logger

  @doc """
  Receives and processes an InvokeThinking event.

  Creates a plan for solving the user query by analyzing available tools
  and the current context.

  ## Parameters

  - `broker`: LLM broker for generating plans
  - `event`: InvokeThinking event containing current context

  ## Returns

  - `{:ok, [InvokeDecisioning.t()]}` with updated context
  - `{:ok, [FailureOccurred.t()]}` on error
  """
  def receive_event_async(%Broker{} = broker, %InvokeThinking{} = event) do
    tools = [DateResolver]

    try do
      prompt = build_prompt(event, tools)
      IO.puts("\n#{format_block(prompt)}")

      # Define schema for Plan structure
      schema = %{
        type: "object",
        properties: %{
          steps: %{
            type: "array",
            items: %{type: "string"},
            description:
              "How to answer the query, step by step, each step outlining an action to take."
          }
        },
        required: ["steps"]
      }

      case Broker.generate_object(broker, [Message.user(prompt)], schema) do
        {:ok, plan_data} ->
          plan = %Plan{steps: Map.get(plan_data, "steps", [])}
          IO.puts("\n#{format_block(inspect(plan, pretty: true))}")

          # Update context with new plan
          updated_context = %{event.context | plan: plan}

          # Add planning step to history
          history_entry =
            ThoughtActionObservation.new(
              "I need to create a plan to solve this query.",
              "Created a step-by-step plan.",
              "Plan has #{length(plan.steps)} steps."
            )

          updated_context = %{
            updated_context
            | history: updated_context.history ++ [history_entry]
          }

          next_event = %InvokeDecisioning{
            source: __MODULE__,
            context: updated_context,
            correlation_id: event.correlation_id
          }

          {:ok, [next_event]}

        {:error, reason} ->
          failure_event = %FailureOccurred{
            source: __MODULE__,
            context: event.context,
            reason: "Error during planning: #{inspect(reason)}",
            correlation_id: event.correlation_id
          }

          {:ok, [failure_event]}
      end
    rescue
      e ->
        failure_event = %FailureOccurred{
          source: __MODULE__,
          context: event.context,
          reason: "Exception during planning: #{Exception.message(e)}",
          correlation_id: event.correlation_id
        }

        {:ok, [failure_event]}
    end
  end

  def receive_event_async(_broker, _event), do: {:ok, []}

  defp build_prompt(event, tools) do
    """
    You are to solve a problem by reasoning and acting on the information you have. Here is the current context:

    #{Formatters.format_current_context(event.context)}
    #{Formatters.format_available_tools(tools)}

    Your Instructions:
    Given our context and what we've done so far, and the tools available, create a step-by-step plan to answer the query.
    Each step should be concrete and actionable. Consider which tools you'll need to use.
    """
    |> String.trim()
  end

  defp format_block(content) do
    width = 80
    border = String.duplicate("=", width)
    "\n#{border}\n#{content}\n#{border}\n"
  end
end
