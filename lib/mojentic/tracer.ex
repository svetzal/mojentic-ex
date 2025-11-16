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

  # Delegate to TracerSystem for all operations
  defdelegate start_link(opts \\ []), to: Mojentic.Tracer.TracerSystem
  defdelegate record_event(server, event), to: Mojentic.Tracer.TracerSystem
  defdelegate record_llm_call(server, opts), to: Mojentic.Tracer.TracerSystem
  defdelegate record_llm_response(server, opts), to: Mojentic.Tracer.TracerSystem
  defdelegate record_tool_call(server, opts), to: Mojentic.Tracer.TracerSystem
  defdelegate record_agent_interaction(server, opts), to: Mojentic.Tracer.TracerSystem
  defdelegate get_events(server, opts \\ []), to: Mojentic.Tracer.TracerSystem
  defdelegate get_last_n_tracer_events(server, n, opts \\ []), to: Mojentic.Tracer.TracerSystem
  defdelegate clear(server), to: Mojentic.Tracer.TracerSystem
  defdelegate enable(server), to: Mojentic.Tracer.TracerSystem
  defdelegate disable(server), to: Mojentic.Tracer.TracerSystem
  defdelegate enabled?(server), to: Mojentic.Tracer.TracerSystem

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
