defmodule Mojentic.Tracer.TracerSystem do
  @moduledoc """
  Central system for capturing and querying tracer events.

  The TracerSystem coordinates event recording through an EventStore and provides
  convenience methods for recording different types of events (LLM calls, tool calls,
  agent interactions) and querying them.

  ## Usage

      # Start a tracer system
      {:ok, tracer} = TracerSystem.start_link()

      # Record an LLM call
      TracerSystem.record_llm_call(tracer,
        model: "gpt-4",
        messages: [%{role: "user", content: "Hello"}],
        temperature: 0.7,
        correlation_id: "abc-123"
      )

      # Record an LLM response
      TracerSystem.record_llm_response(tracer,
        model: "gpt-4",
        content: "Hello! How can I help?",
        call_duration_ms: 123.45,
        correlation_id: "abc-123"
      )

      # Query events
      events = TracerSystem.get_events(tracer)
      llm_calls = TracerSystem.get_events(tracer, event_type: LLMCallTracerEvent)

      # Enable/disable tracing
      TracerSystem.disable(tracer)
      TracerSystem.enable(tracer)

      # Clear events
      TracerSystem.clear(tracer)

  ## Integration

  To integrate with LLM components, pass the tracer as an option:

      broker = Broker.new("gpt-4", gateway, tracer: tracer)
      {:ok, response} = Broker.generate(broker, messages, tools: [tool])

  The broker will automatically record LLM calls and responses.
  """

  use GenServer

  alias Mojentic.Tracer.EventStore
  alias Mojentic.Tracer.TracerEvents.{
    TracerEvent,
    LLMCallTracerEvent,
    LLMResponseTracerEvent,
    ToolCallTracerEvent,
    AgentInteractionTracerEvent
  }

  require Logger

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            event_store: pid(),
            enabled: boolean()
          }

    defstruct [:event_store, enabled: true]
  end

  # Client API

  @doc """
  Starts the TracerSystem GenServer.

  ## Options

  - `:event_store` - Existing EventStore pid (will create new one if not provided)
  - `:enabled` - Whether tracing is enabled (default: true)
  - `:on_store_callback` - Callback function for when events are stored
  - `:name` - Name to register the GenServer under

  ## Examples

      {:ok, tracer} = TracerSystem.start_link()
      {:ok, tracer} = TracerSystem.start_link(enabled: false)
      {:ok, tracer} = TracerSystem.start_link(name: :my_tracer)
  """
  def start_link(opts \\ []) do
    {gen_server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_server_opts)
  end

  @doc """
  Records a generic tracer event.

  ## Examples

      event = %TracerEvent{
        timestamp: System.os_time(:millisecond) / 1000,
        correlation_id: "abc-123",
        source: MyModule
      }
      TracerSystem.record_event(tracer, event)
  """
  @spec record_event(GenServer.server(), TracerEvent.t()) :: :ok
  def record_event(server, event) do
    GenServer.call(server, {:record_event, event})
  end

  @doc """
  Records an LLM call event.

  ## Options

  - `:model` - The LLM model being called (required)
  - `:messages` - Messages sent to the LLM (required)
  - `:temperature` - Temperature setting (default: 1.0)
  - `:tools` - Available tools (default: nil)
  - `:source` - Source module (default: TracerSystem)
  - `:correlation_id` - Correlation ID for tracing (required)

  ## Examples

      TracerSystem.record_llm_call(tracer,
        model: "gpt-4",
        messages: [%{role: "user", content: "Hello"}],
        temperature: 0.7,
        correlation_id: "abc-123"
      )
  """
  @spec record_llm_call(GenServer.server(), keyword()) :: :ok
  def record_llm_call(server, opts) do
    GenServer.call(server, {:record_llm_call, opts})
  end

  @doc """
  Records an LLM response event.

  ## Options

  - `:model` - The LLM model that responded (required)
  - `:content` - Response content (required)
  - `:tool_calls` - Tool calls made by the LLM (default: nil)
  - `:call_duration_ms` - Call duration in milliseconds (default: nil)
  - `:source` - Source module (default: TracerSystem)
  - `:correlation_id` - Correlation ID for tracing (required)

  ## Examples

      TracerSystem.record_llm_response(tracer,
        model: "gpt-4",
        content: "Hello! How can I help?",
        call_duration_ms: 123.45,
        correlation_id: "abc-123"
      )
  """
  @spec record_llm_response(GenServer.server(), keyword()) :: :ok
  def record_llm_response(server, opts) do
    GenServer.call(server, {:record_llm_response, opts})
  end

  @doc """
  Records a tool call event.

  ## Options

  - `:tool_name` - Name of the tool (required)
  - `:arguments` - Tool arguments (required)
  - `:result` - Tool result (required)
  - `:caller` - Name of the caller (default: nil)
  - `:call_duration_ms` - Call duration in milliseconds (default: nil)
  - `:source` - Source module (default: TracerSystem)
  - `:correlation_id` - Correlation ID for tracing (required)

  ## Examples

      TracerSystem.record_tool_call(tracer,
        tool_name: "date_resolver",
        arguments: %{"days_offset" => 3},
        result: "2024-11-18",
        caller: "ChatSession",
        call_duration_ms: 5.67,
        correlation_id: "abc-123"
      )
  """
  @spec record_tool_call(GenServer.server(), keyword()) :: :ok
  def record_tool_call(server, opts) do
    GenServer.call(server, {:record_tool_call, opts})
  end

  @doc """
  Records an agent interaction event.

  ## Options

  - `:from_agent` - Name of sending agent (required)
  - `:to_agent` - Name of receiving agent (required)
  - `:event_type` - Type of event (required)
  - `:event_id` - Event identifier (default: nil)
  - `:source` - Source module (default: TracerSystem)
  - `:correlation_id` - Correlation ID for tracing (required)

  ## Examples

      TracerSystem.record_agent_interaction(tracer,
        from_agent: "AgentA",
        to_agent: "AgentB",
        event_type: "request",
        event_id: "event-123",
        correlation_id: "abc-123"
      )
  """
  @spec record_agent_interaction(GenServer.server(), keyword()) :: :ok
  def record_agent_interaction(server, opts) do
    GenServer.call(server, {:record_agent_interaction, opts})
  end

  @doc """
  Retrieves events from the tracer with optional filtering.

  See `EventStore.get_events/2` for filter options.

  ## Examples

      # Get all events
      events = TracerSystem.get_events(tracer)

      # Filter by type
      llm_calls = TracerSystem.get_events(tracer, event_type: LLMCallTracerEvent)

      # Filter by time and type
      events = TracerSystem.get_events(tracer,
        event_type: ToolCallTracerEvent,
        start_time: start_timestamp,
        end_time: end_timestamp
      )

      # Custom filter
      events = TracerSystem.get_events(tracer,
        filter_func: fn event -> event.correlation_id == "abc-123" end
      )
  """
  @spec get_events(GenServer.server(), keyword()) :: [TracerEvent.t()]
  def get_events(server, opts \\ []) do
    GenServer.call(server, {:get_events, opts})
  end

  @doc """
  Gets the last N tracer events, optionally filtered by type.

  ## Examples

      # Get last 10 events
      recent = TracerSystem.get_last_n_tracer_events(tracer, 10)

      # Get last 5 LLM responses
      recent = TracerSystem.get_last_n_tracer_events(tracer, 5,
        event_type: LLMResponseTracerEvent
      )
  """
  @spec get_last_n_tracer_events(GenServer.server(), non_neg_integer(), keyword()) :: [
          TracerEvent.t()
        ]
  def get_last_n_tracer_events(server, n, opts \\ []) do
    GenServer.call(server, {:get_last_n_tracer_events, n, opts})
  end

  @doc """
  Clears all events from the tracer.

  ## Examples

      :ok = TracerSystem.clear(tracer)
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  @doc """
  Enables the tracer system.

  When enabled, events will be recorded.

  ## Examples

      :ok = TracerSystem.enable(tracer)
  """
  @spec enable(GenServer.server()) :: :ok
  def enable(server) do
    GenServer.call(server, :enable)
  end

  @doc """
  Disables the tracer system.

  When disabled, events will not be recorded.

  ## Examples

      :ok = TracerSystem.disable(tracer)
  """
  @spec disable(GenServer.server()) :: :ok
  def disable(server) do
    GenServer.call(server, :disable)
  end

  @doc """
  Checks if the tracer is enabled.

  ## Examples

      true = TracerSystem.enabled?(tracer)
  """
  @spec enabled?(GenServer.server()) :: boolean()
  def enabled?(server) do
    GenServer.call(server, :enabled?)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    event_store_pid =
      case Keyword.get(opts, :event_store) do
        nil ->
          callback = Keyword.get(opts, :on_store_callback)
          {:ok, pid} = EventStore.start_link(on_store_callback: callback)
          pid

        pid when is_pid(pid) ->
          pid
      end

    state = %State{
      event_store: event_store_pid,
      enabled: Keyword.get(opts, :enabled, true)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:record_event, event}, _from, state) do
    if state.enabled do
      EventStore.store(state.event_store, event)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_llm_call, opts}, _from, state) do
    try do
      if state.enabled do
        event = %LLMCallTracerEvent{
          timestamp: current_timestamp(),
          correlation_id: Keyword.fetch!(opts, :correlation_id),
          source: Keyword.get(opts, :source, __MODULE__),
          model: Keyword.fetch!(opts, :model),
          messages: Keyword.fetch!(opts, :messages),
          temperature: Keyword.get(opts, :temperature, 1.0),
          tools: Keyword.get(opts, :tools)
        }

        EventStore.store(state.event_store, event)
      end

      {:reply, :ok, state}
    rescue
      e in KeyError ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:record_llm_response, opts}, _from, state) do
    try do
      if state.enabled do
        event = %LLMResponseTracerEvent{
          timestamp: current_timestamp(),
          correlation_id: Keyword.fetch!(opts, :correlation_id),
          source: Keyword.get(opts, :source, __MODULE__),
          model: Keyword.fetch!(opts, :model),
          content: Keyword.fetch!(opts, :content),
          tool_calls: Keyword.get(opts, :tool_calls),
          call_duration_ms: Keyword.get(opts, :call_duration_ms)
        }

        EventStore.store(state.event_store, event)
      end

      {:reply, :ok, state}
    rescue
      e in KeyError ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:record_tool_call, opts}, _from, state) do
    try do
      if state.enabled do
        event = %ToolCallTracerEvent{
          timestamp: current_timestamp(),
          correlation_id: Keyword.fetch!(opts, :correlation_id),
          source: Keyword.get(opts, :source, __MODULE__),
          tool_name: Keyword.fetch!(opts, :tool_name),
          arguments: Keyword.fetch!(opts, :arguments),
          result: Keyword.fetch!(opts, :result),
          caller: Keyword.get(opts, :caller),
          call_duration_ms: Keyword.get(opts, :call_duration_ms)
        }

        EventStore.store(state.event_store, event)
      end

      {:reply, :ok, state}
    rescue
      e in KeyError ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:record_agent_interaction, opts}, _from, state) do
    try do
      if state.enabled do
        event = %AgentInteractionTracerEvent{
          timestamp: current_timestamp(),
          correlation_id: Keyword.fetch!(opts, :correlation_id),
          source: Keyword.get(opts, :source, __MODULE__),
          from_agent: Keyword.fetch!(opts, :from_agent),
          to_agent: Keyword.fetch!(opts, :to_agent),
          event_type: Keyword.fetch!(opts, :event_type),
          event_id: Keyword.get(opts, :event_id)
        }

        EventStore.store(state.event_store, event)
      end

      {:reply, :ok, state}
    rescue
      e in KeyError ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_call({:get_events, opts}, _from, state) do
    events = EventStore.get_events(state.event_store, opts)
    {:reply, events, state}
  end

  @impl true
  def handle_call({:get_last_n_tracer_events, n, opts}, _from, state) do
    events = EventStore.get_last_n_events(state.event_store, n, opts)
    {:reply, events, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    EventStore.clear(state.event_store)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    {:reply, :ok, %{state | enabled: true}}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    {:reply, :ok, %{state | enabled: false}}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  # Private Helpers

  defp current_timestamp do
    System.os_time(:millisecond) / 1000
  end
end
