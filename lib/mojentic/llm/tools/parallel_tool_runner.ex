defmodule Mojentic.LLM.Tools.ParallelToolRunner do
  @moduledoc """
  Execute tool calls concurrently using `Task.async_stream/3`.

  `max_concurrency` defaults to 4 — high enough to win meaningfully on
  typical realtime turns (2–3 concurrent function calls), low enough
  that unbounded fan-out into rate-limited APIs doesn't punish users.

  Output order matches input order even though execution is concurrent.
  """

  @behaviour Mojentic.LLM.Tools.Runner

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.LLM.Tools.ToolCallOutcome
  alias Mojentic.LLM.Tools.ToolInvocation

  @default_max_concurrency 4

  defstruct max_concurrency: @default_max_concurrency,
            timeout: :infinity

  @type t :: %__MODULE__{
          max_concurrency: pos_integer(),
          timeout: timeout()
        }

  def new(opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    unless is_integer(max_concurrency) and max_concurrency >= 1 do
      raise ArgumentError, "max_concurrency must be a positive integer"
    end

    %__MODULE__{
      max_concurrency: max_concurrency,
      timeout: Keyword.get(opts, :timeout, :infinity)
    }
  end

  @impl true
  def run_batch(calls, tools, context \\ nil)

  def run_batch([], _tools, _ctx), do: []

  def run_batch(calls, tools, ctx) do
    do_run(new(), calls, tools, ctx)
  end

  @doc """
  Variant that accepts an explicit runner struct so callers can override
  concurrency / timeout per batch.
  """
  def run_with(%__MODULE__{} = runner, calls, tools, ctx \\ nil) do
    do_run(runner, calls, tools, ctx)
  end

  defp do_run(%__MODULE__{} = runner, calls, tools, ctx) do
    calls
    |> Task.async_stream(
      fn call -> run_one(call, tools, ctx) end,
      max_concurrency: runner.max_concurrency,
      timeout: runner.timeout,
      ordered: true,
      on_timeout: :kill_task
    )
    |> Enum.zip(calls)
    |> Enum.map(fn
      {{:ok, outcome}, _call} ->
        outcome

      {{:exit, reason}, call} ->
        outcome = exit_outcome(call, reason)
        ToolInvocation.notify_complete(ctx, outcome)
        outcome
    end)
  end

  defp run_one(%ToolCallExecution{} = call, tools, ctx) do
    if RunContext.cancelled?(ctx || %RunContext{}) do
      outcome = %ToolCallOutcome{
        id: call.id,
        name: call.name,
        ok?: false,
        error: :cancelled,
        duration_ms: 0
      }

      ToolInvocation.notify_complete(ctx, outcome)
      outcome
    else
      ToolInvocation.invoke(call, tools, ctx)
    end
  end

  defp exit_outcome(call, reason) do
    %ToolCallOutcome{
      id: call.id,
      name: call.name,
      ok?: false,
      error: {:task_exit, reason},
      duration_ms: 0
    }
  end
end
