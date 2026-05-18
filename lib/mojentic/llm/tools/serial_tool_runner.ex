defmodule Mojentic.LLM.Tools.SerialToolRunner do
  @moduledoc """
  Execute tool calls one at a time in input order.

  Default for `Mojentic.LLM.Broker` to preserve backward-compatible
  behaviour for the existing recursive-tool-execution loop.
  """

  @behaviour Mojentic.LLM.Tools.Runner

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.LLM.Tools.ToolCallOutcome
  alias Mojentic.LLM.Tools.ToolInvocation

  @impl true
  def run_batch(calls, tools, context \\ nil)

  def run_batch([], _tools, _ctx), do: []

  def run_batch(calls, tools, ctx) do
    Enum.map(calls, fn call ->
      if ctx_cancelled?(ctx) do
        aborted_outcome(call)
      else
        ToolInvocation.invoke(call, tools, ctx)
      end
    end)
  end

  defp ctx_cancelled?(nil), do: false
  defp ctx_cancelled?(%RunContext{} = ctx), do: RunContext.cancelled?(ctx)

  defp aborted_outcome(%ToolCallExecution{} = call) do
    %ToolCallOutcome{
      id: call.id,
      name: call.name,
      ok?: false,
      error: :cancelled,
      duration_ms: 0
    }
  end
end
