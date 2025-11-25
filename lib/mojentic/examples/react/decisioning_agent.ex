defmodule Mojentic.Examples.React.DecisioningAgent do
  @moduledoc """
  Decision-making agent for the ReAct pattern.

  This agent evaluates the current context and decides on the next action to take,
  including whether to plan, act with a tool, or finish and summarize.
  """

  alias Mojentic.Examples.React.Events.{
    FailureOccurred,
    FinishAndSummarize,
    InvokeDecisioning,
    InvokeThinking,
    InvokeToolCall
  }

  alias Mojentic.Examples.React.Formatters
  alias Mojentic.Examples.React.Models.NextAction
  alias Mojentic.LLM.{Broker, Message}
  alias Mojentic.LLM.Tools.DateResolver

  require Logger

  @max_iterations 10

  @doc """
  Receives and processes an InvokeDecisioning event.

  Evaluates the current context and determines the next action (PLAN, ACT, FINISH).

  ## Parameters

  - `broker`: LLM broker for making decisions
  - `event`: InvokeDecisioning event containing current context

  ## Returns

  - `{:ok, [event]}` where event is one of: InvokeToolCall, FinishAndSummarize,
    InvokeThinking, or FailureOccurred
  """
  def receive_event_async(%Broker{} = broker, %InvokeDecisioning{} = event) do
    # Check iteration limit
    if event.context.iteration >= @max_iterations do
      failure_event = %FailureOccurred{
        source: __MODULE__,
        context: event.context,
        reason: "Maximum iterations (#{@max_iterations}) exceeded",
        correlation_id: event.correlation_id
      }

      {:ok, [failure_event]}
    else
      # Increment iteration counter
      updated_context = %{event.context | iteration: event.context.iteration + 1}
      event = %{event | context: updated_context}

      make_decision(broker, event)
    end
  end

  def receive_event_async(_broker, _event), do: {:ok, []}

  defp make_decision(broker, event) do
    tools = [DateResolver]
    prompt = build_prompt(event, tools)
    IO.puts("\n#{format_block(prompt)}")

    schema = %{
      type: "object",
      properties: %{
        thought: %{
          type: "string",
          description: "The reasoning behind the decision"
        },
        next_action: %{
          type: "string",
          enum: ["PLAN", "ACT", "FINISH"],
          description: "What should happen next: PLAN, ACT, or FINISH"
        },
        tool_name: %{
          type: "string",
          description: "Name of tool to use if next_action is ACT"
        },
        tool_arguments: %{
          type: "object",
          description:
            "Arguments for the tool if next_action is ACT. Use exact parameter names from tool descriptor."
        }
      },
      required: ["thought", "next_action"]
    }

    case Broker.generate_object(broker, [Message.user(prompt)], schema) do
      {:ok, decision} ->
        IO.puts("\n#{format_block("Decision: #{inspect(decision, pretty: true)}")}")
        process_decision(decision, event, tools)

      {:error, reason} ->
        failure_event = %FailureOccurred{
          source: __MODULE__,
          context: event.context,
          reason: "Error during decision making: #{inspect(reason)}",
          correlation_id: event.correlation_id
        }

        {:ok, [failure_event]}
    end
  rescue
    e ->
      failure_event = %FailureOccurred{
        source: __MODULE__,
        context: event.context,
        reason: "Exception during decision making: #{Exception.message(e)}",
        correlation_id: event.correlation_id
      }

      {:ok, [failure_event]}
  end

  defp process_decision(decision, event, tools) do
    thought = Map.get(decision, "thought", "")
    next_action_str = Map.get(decision, "next_action", "")

    case NextAction.parse(next_action_str) do
      {:ok, :finish} ->
        finish_event = %FinishAndSummarize{
          source: __MODULE__,
          context: event.context,
          thought: thought,
          correlation_id: event.correlation_id
        }

        {:ok, [finish_event]}

      {:ok, :act} ->
        tool_name = Map.get(decision, "tool_name")
        tool_arguments = Map.get(decision, "tool_arguments", %{})

        if is_nil(tool_name) or tool_name == "" do
          failure_event = %FailureOccurred{
            source: __MODULE__,
            context: event.context,
            reason: "ACT decision made but no tool specified",
            correlation_id: event.correlation_id
          }

          {:ok, [failure_event]}
        else
          # Find the requested tool
          tool_module = find_tool(tools, tool_name)

          if is_nil(tool_module) do
            failure_event = %FailureOccurred{
              source: __MODULE__,
              context: event.context,
              reason: "Tool '#{tool_name}' not found",
              correlation_id: event.correlation_id
            }

            {:ok, [failure_event]}
          else
            tool_call_event = %InvokeToolCall{
              source: __MODULE__,
              context: event.context,
              thought: thought,
              action: :act,
              tool: tool_module,
              tool_arguments: tool_arguments,
              correlation_id: event.correlation_id
            }

            {:ok, [tool_call_event]}
          end
        end

      {:ok, :plan} ->
        thinking_event = %InvokeThinking{
          source: __MODULE__,
          context: event.context,
          correlation_id: event.correlation_id
        }

        {:ok, [thinking_event]}

      {:error, _} ->
        failure_event = %FailureOccurred{
          source: __MODULE__,
          context: event.context,
          reason: "Invalid next_action: #{next_action_str}",
          correlation_id: event.correlation_id
        }

        {:ok, [failure_event]}
    end
  end

  defp find_tool(tools, tool_name) do
    Enum.find(tools, fn tool_module ->
      descriptor = tool_module.descriptor()
      descriptor.function.name == tool_name
    end)
  end

  defp build_prompt(event, tools) do
    """
    You are to solve a problem by reasoning and acting on the information you have. Here is the current context:

    #{Formatters.format_current_context(event.context)}
    #{Formatters.format_available_tools(tools)}

    Your Instructions:
    Review the current plan and history. Decide what to do next:

    1. PLAN - If the plan is incomplete or needs refinement
    2. ACT - If you should take an action using one of the available tools
    3. FINISH - If you have enough information to answer the user's query

    If you choose ACT, specify which tool to use and what arguments to pass.
    Think carefully about whether each step in the plan has been completed.
    """
    |> String.trim()
  end

  defp format_block(content) do
    width = 80
    border = String.duplicate("=", width)
    "\n#{border}\n#{content}\n#{border}\n"
  end
end
