defmodule Mojentic.LLM.Tools.Runner do
  @moduledoc """
  Behaviour for executing batches of tool calls.

  Provides pluggable execution strategies (serial, parallel) so the
  broker stays independent of concurrency policy. Mirrors the
  TypeScript and Python `ToolRunner` abstraction.

  ## Built-in implementations

  - `Mojentic.LLM.Tools.SerialToolRunner` — sequential, in input order.
    Default for `Mojentic.LLM.Broker` to preserve backward-compatibility.
  - `Mojentic.LLM.Tools.ParallelToolRunner` — `Task.async_stream/3` with
    `max_concurrency` (default 4). Default for the realtime broker.

  ## Run context

  Tools may opt in to cancellation by accepting an optional `ctx` arg.
  The context carries an `:cancel_ref` reference and a `:correlation_id`.
  Long-running tools should consult `Mojentic.LLM.Tools.RunContext.cancelled?/1`
  between work units to abort early when the batch is cancelled.

  Tools that don't accept a context continue to work unchanged.
  """

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.LLM.Tools.ToolCallOutcome

  @callback run_batch(
              calls :: [ToolCallExecution.t()],
              tools :: [module() | struct()],
              context :: RunContext.t() | nil
            ) :: [ToolCallOutcome.t()]
end
