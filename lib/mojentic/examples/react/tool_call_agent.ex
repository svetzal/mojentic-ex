defmodule Mojentic.Examples.React.ToolCallAgent do
  @moduledoc """
  Tool execution agent for the ReAct pattern.

  This agent handles the actual execution of tools and captures the results,
  updating the context history with observations.
  """

  alias Mojentic.Examples.React.Events.{FailureOccurred, InvokeDecisioning, InvokeToolCall}
  alias Mojentic.Examples.React.Models.ThoughtActionObservation

  require Logger

  @doc """
  Receives and processes an InvokeToolCall event.

  Executes the specified tool with the provided arguments and updates
  the context with the results.

  ## Parameters

  - `_broker`: LLM broker (unused by this agent)
  - `event`: InvokeToolCall event containing tool and arguments

  ## Returns

  - `{:ok, [InvokeDecisioning.t()]}` with updated context
  - `{:ok, [FailureOccurred.t()]}` on error
  """
  def receive_event_async(_broker, %InvokeToolCall{} = event) do
    try do
      tool_module = event.tool
      tool = tool_module.new()
      descriptor = tool_module.descriptor()
      tool_name = descriptor.function.name
      arguments = event.tool_arguments

      IO.puts("\nExecuting tool: #{tool_name}")
      IO.puts("Arguments: #{inspect(arguments, pretty: true)}")

      case tool_module.run(tool, arguments) do
        {:ok, result} ->
          IO.puts("Result: #{inspect(result, pretty: true)}")

          result_text = extract_result_text(result)

          # Add to history
          history_entry =
            ThoughtActionObservation.new(
              event.thought,
              "Called #{tool_name} with #{inspect(arguments)}",
              result_text
            )

          updated_context = %{
            event.context
            | history: event.context.history ++ [history_entry]
          }

          # Continue to decisioning
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
            reason: "Tool execution failed: #{inspect(reason)}",
            correlation_id: event.correlation_id
          }

          {:ok, [failure_event]}
      end
    rescue
      e ->
        Logger.error("Tool execution exception: #{Exception.message(e)}")

        failure_event = %FailureOccurred{
          source: __MODULE__,
          context: event.context,
          reason: "Tool execution exception: #{Exception.message(e)}",
          correlation_id: event.correlation_id
        }

        {:ok, [failure_event]}
    end
  end

  def receive_event_async(_broker, _event), do: {:ok, []}

  defp extract_result_text(result) when is_binary(result), do: result

  defp extract_result_text(result) when is_map(result) do
    cond do
      Map.has_key?(result, :summary) -> Map.get(result, :summary)
      Map.has_key?(result, "summary") -> Map.get(result, "summary")
      Map.has_key?(result, :content) -> extract_content(Map.get(result, :content))
      Map.has_key?(result, "content") -> extract_content(Map.get(result, "content"))
      true -> inspect(result, pretty: true)
    end
  end

  defp extract_result_text(result), do: inspect(result, pretty: true)

  defp extract_content(content) when is_list(content) do
    Enum.map_join(content, " ", fn item ->
      cond do
        is_map(item) and Map.has_key?(item, :text) -> Map.get(item, :text)
        is_map(item) and Map.has_key?(item, "text") -> Map.get(item, "text")
        true -> inspect(item)
      end
    end)
  end

  defp extract_content(content), do: inspect(content)
end
