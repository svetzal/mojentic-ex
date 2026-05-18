defmodule Mojentic.LLM.Tools.RunContext do
  @moduledoc """
  Context handed to a tool runner (and, optionally, to tools that opt in)
  for a single batch.

  Tools may declare a second arg `ctx :: RunContext.t()` on their
  `run/2` callback to observe cancellation. The runner inspects the
  callback's exported arity and passes the context only when the
  callback was implemented as `run/2`-with-ctx vs the legacy
  `run/1`-shape.
  """

  defstruct cancel_ref: nil,
            cancelled?: false,
            correlation_id: nil,
            source: nil,
            on_call_start: nil,
            on_call_complete: nil

  @type t :: %__MODULE__{
          cancel_ref: reference() | nil,
          cancelled?: boolean(),
          correlation_id: String.t() | nil,
          source: String.t() | nil,
          on_call_start: (Mojentic.LLM.Tools.ToolCallExecution.t() -> :ok) | nil,
          on_call_complete: (Mojentic.LLM.Tools.ToolCallOutcome.t() -> :ok) | nil
        }

  @doc """
  Construct a new run context.
  """
  def new(opts \\ []) do
    %__MODULE__{
      cancel_ref: Keyword.get(opts, :cancel_ref),
      correlation_id: Keyword.get(opts, :correlation_id),
      source: Keyword.get(opts, :source),
      on_call_start: Keyword.get(opts, :on_call_start),
      on_call_complete: Keyword.get(opts, :on_call_complete)
    }
  end

  @doc """
  Returns true if the cancel ref has been signalled.

  When `cancel_ref` is an `:atomics` reference we treat any non-zero
  value as cancelled. When nil, always returns false.
  """
  def cancelled?(%__MODULE__{cancel_ref: nil}), do: false
  def cancelled?(%__MODULE__{cancelled?: true}), do: true

  def cancelled?(%__MODULE__{cancel_ref: ref}) when is_reference(ref) do
    try do
      :atomics.get(ref, 1) != 0
    rescue
      _ -> false
    end
  end

  @doc """
  Signal cancellation. Subsequent `cancelled?/1` checks return true.
  """
  def cancel(%__MODULE__{cancel_ref: ref}) when is_reference(ref) do
    :atomics.put(ref, 1, 1)
  end

  def cancel(_ctx), do: :ok
end
