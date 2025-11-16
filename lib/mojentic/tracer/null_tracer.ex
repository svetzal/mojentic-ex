defmodule Mojentic.Tracer.NullTracer do
  @moduledoc """
  A no-op implementation of TracerSystem following the Null Object Pattern.

  The NullTracer provides the same API as TracerSystem but performs no operations,
  eliminating the need for conditional checks in client code. All record methods
  return `:ok` but do nothing, and all query methods return empty lists.

  ## Usage

      # Use the singleton null tracer instance
      alias Mojentic.Tracer

      # Pass to components that optionally accept a tracer
      broker = Broker.new("gpt-4", gateway, tracer: Tracer.null_tracer())

      # All operations are no-ops
      Tracer.null_tracer() |> NullTracer.record_llm_call(...)  # Does nothing
      Tracer.null_tracer() |> NullTracer.get_events()          # Returns []

  ## Benefits

  - Eliminates conditional tracing checks throughout codebase
  - Same API as TracerSystem for seamless substitution
  - Zero overhead when tracing is disabled
  - Cleaner code without `if tracer != nil` checks
  """

  alias Mojentic.Tracer.TracerEvents.TracerEvent

  @doc """
  No-op: Does not record the event.

  ## Examples

      event = %TracerEvent{...}
      :ok = NullTracer.record_event(:null_tracer, event)
  """
  @spec record_event(atom(), TracerEvent.t()) :: :ok
  def record_event(_server, _event), do: :ok

  @doc """
  No-op: Does not record the LLM call.

  ## Examples

      :ok = NullTracer.record_llm_call(:null_tracer,
        model: "gpt-4",
        messages: [],
        correlation_id: "abc"
      )
  """
  @spec record_llm_call(atom(), keyword()) :: :ok
  def record_llm_call(_server, _opts), do: :ok

  @doc """
  No-op: Does not record the LLM response.

  ## Examples

      :ok = NullTracer.record_llm_response(:null_tracer,
        model: "gpt-4",
        content: "Hello",
        correlation_id: "abc"
      )
  """
  @spec record_llm_response(atom(), keyword()) :: :ok
  def record_llm_response(_server, _opts), do: :ok

  @doc """
  No-op: Does not record the tool call.

  ## Examples

      :ok = NullTracer.record_tool_call(:null_tracer,
        tool_name: "date_resolver",
        arguments: %{},
        result: "2024-11-15",
        correlation_id: "abc"
      )
  """
  @spec record_tool_call(atom(), keyword()) :: :ok
  def record_tool_call(_server, _opts), do: :ok

  @doc """
  No-op: Does not record the agent interaction.

  ## Examples

      :ok = NullTracer.record_agent_interaction(:null_tracer,
        from_agent: "A",
        to_agent: "B",
        event_type: "request",
        correlation_id: "abc"
      )
  """
  @spec record_agent_interaction(atom(), keyword()) :: :ok
  def record_agent_interaction(_server, _opts), do: :ok

  @doc """
  Always returns an empty list.

  ## Examples

      [] = NullTracer.get_events(:null_tracer)
      [] = NullTracer.get_events(:null_tracer, event_type: LLMCallTracerEvent)
  """
  @spec get_events(atom(), keyword()) :: []
  def get_events(_server, _opts \\ []), do: []

  @doc """
  Always returns an empty list.

  ## Examples

      [] = NullTracer.get_last_n_tracer_events(:null_tracer, 10)
  """
  @spec get_last_n_tracer_events(atom(), non_neg_integer(), keyword()) :: []
  def get_last_n_tracer_events(_server, _n, _opts \\ []), do: []

  @doc """
  No-op: Does nothing.

  ## Examples

      :ok = NullTracer.clear(:null_tracer)
  """
  @spec clear(atom()) :: :ok
  def clear(_server), do: :ok

  @doc """
  No-op: Does nothing.

  ## Examples

      :ok = NullTracer.enable(:null_tracer)
  """
  @spec enable(atom()) :: :ok
  def enable(_server), do: :ok

  @doc """
  No-op: Does nothing.

  ## Examples

      :ok = NullTracer.disable(:null_tracer)
  """
  @spec disable(atom()) :: :ok
  def disable(_server), do: :ok

  @doc """
  Always returns false.

  ## Examples

      false = NullTracer.enabled?(:null_tracer)
  """
  @spec enabled?(atom()) :: false
  def enabled?(_server), do: false
end
