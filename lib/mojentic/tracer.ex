defmodule Mojentic.Tracer do
  @moduledoc """
  Public API for the Mojentic Tracer System.

  The tracer system provides observability and debugging capabilities by recording
  LLM calls, tool executions, and agent interactions. All events include correlation
  IDs for tracing related operations across the system.

  ## Quick Start

      # Start a tracer
      {:ok, tracer} = Tracer.start_link()

      # Pass to components
      broker = Broker.new("gpt-4", gateway, tracer: tracer)
      {:ok, response} = Broker.generate(broker, messages, tools: [tool])

      # Query events
      events = Tracer.get_events(tracer)
      llm_calls = Tracer.get_events(tracer, event_type: LLMCallTracerEvent)

  ## Null Tracer

  When tracing is not needed, use the null tracer to avoid overhead:

      broker = Broker.new("gpt-4", gateway, tracer: Tracer.null_tracer())

  ## Event Types

  - `TracerEvent` - Base event type
  - `LLMCallTracerEvent` - Records LLM calls
  - `LLMResponseTracerEvent` - Records LLM responses
  - `ToolCallTracerEvent` - Records tool executions
  - `AgentInteractionTracerEvent` - Records agent-to-agent interactions

  ## Filtering Events

      # By type
      llm_calls = Tracer.get_events(tracer, event_type: LLMCallTracerEvent)

      # By time range
      recent = Tracer.get_events(tracer,
        start_time: start_timestamp,
        end_time: end_timestamp
      )

      # By correlation ID
      related = Tracer.get_events(tracer,
        filter_func: fn event -> event.correlation_id == "abc-123" end
      )

      # Last N events
      recent = Tracer.get_last_n_tracer_events(tracer, 10)

  ## Correlation IDs

  Correlation IDs allow tracing related events across system boundaries:

      alias UUID

      correlation_id = UUID.uuid4()

      # Pass the same correlation_id to all related operations
      Tracer.record_llm_call(tracer,
        model: "gpt-4",
        messages: messages,
        correlation_id: correlation_id
      )

      Tracer.record_tool_call(tracer,
        tool_name: "date_resolver",
        arguments: args,
        result: result,
        correlation_id: correlation_id
      )

      # Query all related events
      related_events = Tracer.get_events(tracer,
        filter_func: fn e -> e.correlation_id == correlation_id end
      )
  """

  alias Mojentic.Tracer.TracerSystem
  alias Mojentic.Tracer.NullTracer

  # Delegate to TracerSystem for start_link
  defdelegate start_link(opts \\ []), to: TracerSystem

  @doc """
  Records a generic tracer event.
  """
  def record_event(:null_tracer, event), do: NullTracer.record_event(:null_tracer, event)
  def record_event(server, event), do: TracerSystem.record_event(server, event)

  @doc """
  Records an LLM call event.
  """
  def record_llm_call(:null_tracer, opts), do: NullTracer.record_llm_call(:null_tracer, opts)
  def record_llm_call(server, opts), do: TracerSystem.record_llm_call(server, opts)

  @doc """
  Records an LLM response event.
  """
  def record_llm_response(:null_tracer, opts),
    do: NullTracer.record_llm_response(:null_tracer, opts)

  def record_llm_response(server, opts), do: TracerSystem.record_llm_response(server, opts)

  @doc """
  Records a tool call event.
  """
  def record_tool_call(:null_tracer, opts), do: NullTracer.record_tool_call(:null_tracer, opts)
  def record_tool_call(server, opts), do: TracerSystem.record_tool_call(server, opts)

  @doc """
  Records an agent interaction event.
  """
  def record_agent_interaction(:null_tracer, opts),
    do: NullTracer.record_agent_interaction(:null_tracer, opts)

  def record_agent_interaction(server, opts),
    do: TracerSystem.record_agent_interaction(server, opts)

  @doc """
  Retrieves events from the tracer.
  """
  def get_events(server, opts \\ [])
  def get_events(:null_tracer, opts), do: NullTracer.get_events(:null_tracer, opts)
  def get_events(server, opts), do: TracerSystem.get_events(server, opts)

  @doc """
  Gets the last N tracer events.
  """
  def get_last_n_tracer_events(server, n, opts \\ [])

  def get_last_n_tracer_events(:null_tracer, n, opts),
    do: NullTracer.get_last_n_tracer_events(:null_tracer, n, opts)

  def get_last_n_tracer_events(server, n, opts),
    do: TracerSystem.get_last_n_tracer_events(server, n, opts)

  @doc """
  Clears all events from the tracer.
  """
  def clear(:null_tracer), do: NullTracer.clear(:null_tracer)
  def clear(server), do: TracerSystem.clear(server)

  @doc """
  Enables the tracer system.
  """
  def enable(:null_tracer), do: NullTracer.enable(:null_tracer)
  def enable(server), do: TracerSystem.enable(server)

  @doc """
  Disables the tracer system.
  """
  def disable(:null_tracer), do: NullTracer.disable(:null_tracer)
  def disable(server), do: TracerSystem.disable(server)

  @doc """
  Checks if the tracer is enabled.
  """
  def enabled?(:null_tracer), do: NullTracer.enabled?(:null_tracer)
  def enabled?(server), do: TracerSystem.enabled?(server)

  @doc """
  Returns the singleton null tracer instance.

  The null tracer implements the same API as TracerSystem but performs no operations,
  following the Null Object Pattern. This eliminates conditional checks in code.

  ## Examples

      # Use null tracer when tracing is not needed
      broker = Broker.new("gpt-4", gateway, tracer: Tracer.null_tracer())

      # All operations are no-ops
      Tracer.record_llm_call(Tracer.null_tracer(), ...)  # Does nothing
      Tracer.get_events(Tracer.null_tracer())            # Returns []
  """
  @spec null_tracer() :: :null_tracer
  def null_tracer, do: :null_tracer
end
