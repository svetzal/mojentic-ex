defmodule Mojentic.LLM.Tools.ToolInvocation do
  @moduledoc """
  Internal helper that invokes a single tool call against a resolved
  tool, honouring the optional run-context contract, and packages the
  result into a `Mojentic.LLM.Tools.ToolCallOutcome`.

  Tools may accept either `run/2` (the existing two-arg form,
  `run(tool, args)`) or, when they implement
  `Mojentic.LLM.Tools.RunContext`-aware semantics, `run/3`
  (`run(tool, args, ctx)`). The invocation helper detects which is
  exported and dispatches accordingly.
  """

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.Tool
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.LLM.Tools.ToolCallOutcome

  @doc """
  Resolve and invoke a single tool. Always returns a
  `ToolCallOutcome` — exceptions are caught and surfaced as
  `ok?: false`.
  """
  def invoke(%ToolCallExecution{} = call, tools, ctx \\ nil) do
    start = System.monotonic_time(:millisecond)
    fire_on_start(ctx, call)

    outcome =
      case find_tool(tools, call.name) do
        nil ->
          %ToolCallOutcome{
            id: call.id,
            name: call.name,
            ok?: false,
            error: {:tool_not_found, call.name},
            duration_ms: System.monotonic_time(:millisecond) - start
          }

        tool ->
          execute(tool, call, ctx, start)
      end

    fire_on_complete(ctx, outcome)
    outcome
  end

  defp execute(tool, %ToolCallExecution{} = call, ctx, start) do
    module = tool_module(tool)

    result =
      try do
        if function_exported?(module, :run, 3) and ctx != nil do
          module.run(tool, call.args, ctx)
        else
          Tool.run(tool, call.args)
        end
      rescue
        err -> {:error, {:exception, err}}
      catch
        kind, payload -> {:error, {kind, payload}}
      end

    duration_ms = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, value} ->
        %ToolCallOutcome{
          id: call.id,
          name: call.name,
          ok?: true,
          result: value,
          duration_ms: duration_ms
        }

      {:error, reason} ->
        %ToolCallOutcome{
          id: call.id,
          name: call.name,
          ok?: false,
          error: reason,
          duration_ms: duration_ms
        }

      other ->
        # Tolerate tools that return a bare value rather than {:ok, _}.
        %ToolCallOutcome{
          id: call.id,
          name: call.name,
          ok?: true,
          result: other,
          duration_ms: duration_ms
        }
    end
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn t -> Tool.matches?(t, name) end)
  end

  defp tool_module(tool) when is_atom(tool), do: tool
  defp tool_module(%module{}), do: module

  defp fire_on_start(%RunContext{on_call_start: fun}, call) when is_function(fun, 1) do
    try do
      fun.(call)
    rescue
      _ -> :ok
    end
  end

  defp fire_on_start(_, _), do: :ok

  defp fire_on_complete(%RunContext{on_call_complete: fun}, outcome) when is_function(fun, 1) do
    try do
      fun.(outcome)
    rescue
      _ -> :ok
    end
  end

  defp fire_on_complete(_, _), do: :ok
end
