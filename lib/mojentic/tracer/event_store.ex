defmodule Mojentic.Tracer.EventStore do
  @moduledoc """
  GenServer for storing and querying tracer events.

  The EventStore provides persistent storage for tracer events with support for:
  - Storing events with optional callbacks
  - Filtering by event type, time range, and custom functions
  - Querying the last N events
  - Clearing all events

  ## Examples

      # Start the event store
      {:ok, pid} = EventStore.start_link([])

      # Store an event
      event = %TracerEvent{...}
      :ok = EventStore.store(pid, event)

      # Get all events
      events = EventStore.get_events(pid)

      # Get events by type
      llm_events = EventStore.get_events(pid, event_type: LLMCallTracerEvent)

      # Get events by time range
      events = EventStore.get_events(pid,
        start_time: start_timestamp,
        end_time: end_timestamp
      )

      # Get last N events
      recent = EventStore.get_last_n_events(pid, 10)

      # Clear all events
      :ok = EventStore.clear(pid)
  """

  use GenServer
  require Logger

  alias Mojentic.Tracer.TracerEvents.TracerEvent

  @type event_type :: module()
  @type filter_func :: (TracerEvent.t() -> boolean())
  @type on_store_callback :: (TracerEvent.t() -> any())

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            events: [TracerEvent.t()],
            on_store_callback: (TracerEvent.t() -> any()) | nil
          }

    defstruct events: [], on_store_callback: nil
  end

  # Client API

  @doc """
  Starts the EventStore GenServer.

  ## Options

  - `:on_store_callback` - Function called whenever an event is stored
  - `:name` - Name to register the GenServer under

  ## Examples

      {:ok, pid} = EventStore.start_link([])
      {:ok, pid} = EventStore.start_link(name: :my_event_store)
      {:ok, pid} = EventStore.start_link(on_store_callback: &IO.inspect/1)
  """
  def start_link(opts \\ []) do
    {gen_server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_server_opts)
  end

  @doc """
  Stores an event in the event store.

  If an `on_store_callback` was provided during initialization, it will be called
  with the stored event.

  ## Examples

      event = %TracerEvent{...}
      :ok = EventStore.store(pid, event)
  """
  @spec store(GenServer.server(), TracerEvent.t()) :: :ok
  def store(server, event) do
    GenServer.call(server, {:store, event})
  end

  @doc """
  Retrieves events from the store with optional filtering.

  ## Options

  - `:event_type` - Filter by specific event type (module)
  - `:start_time` - Include events with timestamp >= start_time
  - `:end_time` - Include events with timestamp <= end_time
  - `:filter_func` - Custom filter function that returns true for events to include

  ## Examples

      # Get all events
      events = EventStore.get_events(pid)

      # Filter by type
      llm_calls = EventStore.get_events(pid, event_type: LLMCallTracerEvent)

      # Filter by time range
      recent = EventStore.get_events(pid,
        start_time: start_timestamp,
        end_time: end_timestamp
      )

      # Custom filter
      events = EventStore.get_events(pid,
        filter_func: fn event -> event.correlation_id == "abc-123" end
      )
  """
  @spec get_events(GenServer.server(), keyword()) :: [TracerEvent.t()]
  def get_events(server, opts \\ []) do
    GenServer.call(server, {:get_events, opts})
  end

  @doc """
  Gets the last N events, optionally filtered by type.

  ## Examples

      # Get last 10 events
      recent = EventStore.get_last_n_events(pid, 10)

      # Get last 5 LLM call events
      recent_calls = EventStore.get_last_n_events(pid, 5,
        event_type: LLMCallTracerEvent
      )
  """
  @spec get_last_n_events(GenServer.server(), non_neg_integer(), keyword()) :: [TracerEvent.t()]
  def get_last_n_events(server, n, opts \\ []) do
    GenServer.call(server, {:get_last_n_events, n, opts})
  end

  @doc """
  Clears all events from the store.

  ## Examples

      :ok = EventStore.clear(pid)
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %State{
      events: [],
      on_store_callback: Keyword.get(opts, :on_store_callback)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:store, event}, _from, state) do
    new_events = state.events ++ [event]
    new_state = %{state | events: new_events}

    # Call the callback if it exists
    if state.on_store_callback do
      try do
        state.on_store_callback.(event)
      rescue
        error ->
          Logger.warning("EventStore callback error: #{inspect(error)}")
      end
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_events, opts}, _from, state) do
    events = apply_filters(state.events, opts)
    {:reply, events, state}
  end

  @impl true
  def handle_call({:get_last_n_events, n, opts}, _from, state) do
    filtered_events =
      case Keyword.get(opts, :event_type) do
        nil -> state.events
        event_type -> Enum.filter(state.events, fn e -> e.__struct__ == event_type end)
      end

    events = Enum.take(filtered_events, -n)
    {:reply, events, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | events: []}}
  end

  # Private Helpers

  defp apply_filters(events, opts) do
    events
    |> filter_by_type(Keyword.get(opts, :event_type))
    |> filter_by_time_range(
      Keyword.get(opts, :start_time),
      Keyword.get(opts, :end_time)
    )
    |> filter_by_custom(Keyword.get(opts, :filter_func))
  end

  defp filter_by_type(events, nil), do: events

  defp filter_by_type(events, event_type) do
    Enum.filter(events, fn event -> event.__struct__ == event_type end)
  end

  defp filter_by_time_range(events, nil, nil), do: events
  defp filter_by_time_range(events, start_time, nil) do
    Enum.filter(events, fn event -> event.timestamp >= start_time end)
  end

  defp filter_by_time_range(events, nil, end_time) do
    Enum.filter(events, fn event -> event.timestamp <= end_time end)
  end

  defp filter_by_time_range(events, start_time, end_time) do
    Enum.filter(events, fn event ->
      event.timestamp >= start_time && event.timestamp <= end_time
    end)
  end

  defp filter_by_custom(events, nil), do: events

  defp filter_by_custom(events, filter_func) when is_function(filter_func, 1) do
    Enum.filter(events, filter_func)
  end
end
