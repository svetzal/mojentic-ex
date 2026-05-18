# Parallel Tool Execution

Mojentic factors tool-batch execution behind a `Mojentic.LLM.Tools.Runner`
behaviour so the broker stays independent of concurrency policy:

| Runner | Behaviour | Default for |
|---|---|---|
| `SerialToolRunner` | Sequential, in input order. | `Mojentic.LLM.Broker` (backward-compatible) |
| `ParallelToolRunner` | `Task.async_stream/3` with `max_concurrency: 4` by default. Preserves output order. | `Mojentic.Realtime.Broker` |

## Opt-in for the chat broker

```elixir
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Tools.ParallelToolRunner
alias Mojentic.LLM.Gateways.OpenAI

broker =
  Broker.new(
    "gpt-4o",
    OpenAI,
    tool_runner: ParallelToolRunner
  )

{:ok, _response} = Broker.generate(broker, [Message.user("...")], [MyTool])
```

When the model returns multiple `tool_calls` in a single assistant
turn, the broker fans them out concurrently. Output order is
preserved so the tool messages submitted back to the model match the
original call order.

## Cancellation

Tools may opt in to cancellation by implementing `run/3` (with a
`Mojentic.LLM.Tools.RunContext` as the third arg) instead of `run/2`.
The runner inspects the exported arity via `function_exported?/3` and
only passes the context when the tool advertises it — existing
`run/2` tools work unchanged.

```elixir
defmodule SlowTool do
  @behaviour Mojentic.LLM.Tools.Tool

  alias Mojentic.LLM.Tools.RunContext

  @impl true
  def run(tool, args), do: do_work(tool, args, nil)

  def run(tool, args, %RunContext{} = ctx) do
    if RunContext.cancelled?(ctx) do
      {:error, :cancelled}
    else
      do_work(tool, args, ctx)
    end
  end

  @impl true
  def descriptor, do: %{...}

  defp do_work(_tool, _args, _ctx), do: {:ok, "done"}
end
```

## Batch tracer event

`ParallelToolRunner` (and the realtime broker) emit a
`ToolBatchTracerEvent` alongside the per-call `ToolCallTracerEvent`s,
so observers can measure parallelism gains. Pull them with
`Tracer.record_tool_batch/2`-aware queries through the standard
`TracerSystem` API.
