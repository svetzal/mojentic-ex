defmodule Mojentic.Examples.React.Formatters do
  @moduledoc """
  Formatting utilities for the ReAct pattern implementation.

  This module provides helper functions for formatting context and tool information
  into human-readable strings for LLM prompts.
  """

  alias Mojentic.Examples.React.Models.CurrentContext

  @doc """
  Formats the current context into a readable string.

  ## Parameters

  - `context`: The current context containing query, plan, and history

  ## Returns

  A formatted multi-line string describing the current context.

  ## Examples

      iex> context = CurrentContext.new("What is the date next Friday?")
      iex> Formatters.format_current_context(context)
      "Current Context:\\nThe user has asked us to answer the following query:\\n> What is the date next Friday?\\n..."

  """
  def format_current_context(%CurrentContext{} = context) do
    user_query = """
    The user has asked us to answer the following query:
    > #{context.user_query}
    """

    plan =
      if Enum.empty?(context.plan.steps) do
        "You have not yet made a plan.\n"
      else
        steps = Enum.map_join(context.plan.steps, "\n", &"- #{&1}")

        "Current plan:\n#{steps}\n"
      end

    history =
      if Enum.empty?(context.history) do
        "No steps have yet been taken.\n"
      else
        steps =
          context.history
          |> Enum.with_index(1)
          |> Enum.map_join("", fn {step, i} ->
            """
            #{i}.
                Thought: #{step.thought}
                Action: #{step.action}
                Observation: #{step.observation}
            """
          end)

        "What's been done so far:\n#{steps}"
      end

    "Current Context:\n#{user_query}#{plan}#{history}\n"
  end

  @doc """
  Formats the available tools into a readable list.

  ## Parameters

  - `tools`: A list of tool modules

  ## Returns

  A formatted string listing available tools and their descriptions.

  ## Examples

      iex> tools = [Mojentic.LLM.Tools.DateResolver]
      iex> Formatters.format_available_tools(tools)
      "Tools available:\\n- resolve_date: Take text that specifies a relative date, and output an absolute date\\n..."

  """
  def format_available_tools(tools) when is_list(tools) do
    if Enum.empty?(tools) do
      ""
    else
      tool_descriptions = Enum.map_join(tools, "\n", &format_tool/1)

      "Tools available:\n#{tool_descriptions}"
    end
  end

  defp format_tool(tool_module) do
    _tool = tool_module.new()
    descriptor = tool_module.descriptor()
    func = descriptor.function

    params_desc =
      case func[:parameters] do
        nil ->
          ""

        params ->
          props = params[:properties] || %{}
          required = params[:required] || []

          if Enum.empty?(props) do
            ""
          else
            param_lines =
              Enum.map_join(props, "\n", fn {param_name, param_info} ->
                is_required = param_name in required or to_string(param_name) in required
                req_str = if is_required, do: " (required)", else: " (optional)"
                desc = param_info[:description] || ""
                "    - #{param_name}#{req_str}: #{desc}"
              end)

            "\n  Parameters:\n#{param_lines}"
          end
      end

    "- #{func.name}: #{func.description}#{params_desc}"
  end
end
