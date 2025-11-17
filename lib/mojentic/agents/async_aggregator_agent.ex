defmodule Mojentic.Agents.AsyncAggregatorAgent do
  @moduledoc """
  GenServer-based agent that aggregates events by correlation ID.

  The aggregator waits for multiple event types before processing them together.
  This is useful for coordinating parallel async operations that need to be
  combined (e.g., waiting for fact-checking and answer generation before
  producing a final answer).

  ## Features

  - **Event Accumulation** - Collects events by correlation_id
  - **Type Tracking** - Waits for specific event types via `event_types_needed`
  - **Timeout Support** - Configurable timeout for `wait_for_events/3`
  - **Custom Processing** - Override `process_events/2` callback

  ## State Structure

      %{
        events: %{correlation_id => [events]},
        waiters: %{correlation_id => [caller_pids]},
        event_types_needed: [EventType1, EventType2, ...]
      }

  ## Usage

  Start the aggregator as a supervised process:

      {:ok, pid} = AsyncAggregatorAgent.start_link(
        event_types_needed: [FactCheckEvent, AnswerEvent],
        process_events_fn: &MyModule.process_events/2
      )

  Or implement as a module:

      defmodule FinalAnswerAgent do
        use Mojentic.Agents.AsyncAggregatorAgent

        def start_link(opts) do
          AsyncAggregatorAgent.start_link(
            event_types_needed: [FactCheckEvent, AnswerEvent],
            process_events_fn: &__MODULE__.process_events/2,
            name: __MODULE__
          )
        end

        def process_events(events, state) do
          fact_event = Enum.find(events, &match?(%FactCheckEvent{}, &1))
          answer_event = Enum.find(events, &match?(%AnswerEvent{}, &1))

          final_event = %FinalAnswerEvent{
            source: __MODULE__,
            correlation_id: fact_event.correlation_id,
            answer: answer_event.answer,
            facts: fact_event.facts
          }

          {:ok, [final_event], state}
        end
      end

  ## Examples

      # Start the aggregator
      {:ok, pid} = AsyncAggregatorAgent.start_link(
        event_types_needed: [EventA, EventB],
        process_events_fn: &process/2
      )

      # Dispatch events (via dispatcher or directly)
      AsyncAggregatorAgent.receive_event(pid, event_a)
      AsyncAggregatorAgent.receive_event(pid, event_b)

      # Wait for all needed events
      {:ok, result_events} = AsyncAggregatorAgent.wait_for_events(
        pid,
        correlation_id,
        timeout: 5000
      )

  """

  use GenServer

  alias Mojentic.Event

  require Logger

  @type state :: %{
          events: %{String.t() => [Event.t()]},
          results: %{String.t() => [Event.t()]},
          waiters: %{String.t() => [GenServer.from()]},
          event_types_needed: [module()],
          process_events_fn: ([Event.t()], state() -> {:ok, [Event.t()], state()})
        }

  ## Client API

  @doc """
  Starts the aggregator agent as a linked process.

  ## Options

  - `:event_types_needed` - List of event type modules to wait for (required)
  - `:process_events_fn` - Function to call when all events collected (required)
  - `:name` - Process registration name (optional)

  ## Examples

      {:ok, pid} = AsyncAggregatorAgent.start_link(
        event_types_needed: [EventA, EventB],
        process_events_fn: &MyModule.process/2
      )

  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Receives an event and processes it according to async agent behaviour.

  This is the main entry point called by the dispatcher. The agent will:
  1. Store the event under its correlation_id
  2. Check if all needed event types have arrived
  3. If complete, call `process_events_fn` and notify waiters
  4. Return the resulting events

  ## Parameters

  - `pid` - The aggregator process
  - `event` - The event to process

  ## Returns

  - `{:ok, [Event.t()]}` - Successfully processed, returns new events
  - `{:error, reason}` - Processing failed

  ## Examples

      {:ok, events} = AsyncAggregatorAgent.receive_event(pid, event)

  """
  def receive_event(pid, event) do
    GenServer.call(pid, {:receive_event, event}, :infinity)
  end

  @doc """
  Waits for all needed events for a specific correlation_id.

  This function blocks the caller until all required event types have been
  received for the given correlation_id, or until the timeout is reached.

  ## Parameters

  - `pid` - The aggregator process
  - `correlation_id` - The correlation ID to wait for
  - `opts` - Keyword list with:
    - `:timeout` - Maximum wait time in milliseconds (default: 5000)

  ## Returns

  - `{:ok, [Event.t()]}` - All events received and processed
  - `{:error, :timeout}` - Timeout reached before all events arrived

  ## Examples

      {:ok, events} = AsyncAggregatorAgent.wait_for_events(
        pid,
        "correlation-123",
        timeout: 10_000
      )

  """
  def wait_for_events(pid, correlation_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(pid, {:wait_for_events, correlation_id}, timeout)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    event_types_needed = Keyword.fetch!(opts, :event_types_needed)
    process_events_fn = Keyword.fetch!(opts, :process_events_fn)

    state = %{
      events: %{},
      results: %{},
      waiters: %{},
      event_types_needed: event_types_needed,
      process_events_fn: process_events_fn
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:receive_event, event}, _from, state) do
    correlation_id = event.correlation_id

    # Check if we already have results for this correlation_id
    case Map.get(state.results, correlation_id) do
      nil ->
        # Store the event
        events = Map.get(state.events, correlation_id, [])
        events = [event | events]
        state = put_in(state.events[correlation_id], events)

        # Check if we have all needed event types
        case check_completion(events, state.event_types_needed) do
          :complete ->
            # Process events
            case state.process_events_fn.(events, state) do
              {:ok, result_events, new_state} ->
                # Store results and notify all waiters using GenServer.reply
                new_state = put_in(new_state.results[correlation_id], result_events)
                waiters = Map.get(new_state.waiters, correlation_id, [])

                Enum.each(waiters, fn waiter_from ->
                  GenServer.reply(waiter_from, {:ok, result_events})
                end)

                # Clean up events and waiters (but keep results)
                new_state =
                  new_state
                  |> Map.update!(:events, &Map.delete(&1, correlation_id))
                  |> Map.update!(:waiters, &Map.delete(&1, correlation_id))

                {:reply, {:ok, result_events}, new_state}

              {:error, reason} ->
                Logger.error("Failed to process events: #{inspect(reason)}")
                {:reply, {:error, reason}, state}
            end

          :incomplete ->
            {:reply, {:ok, []}, state}
        end

      result_events ->
        # Already processed, return cached results
        {:reply, {:ok, result_events}, state}
    end
  end

  @impl true
  def handle_call({:wait_for_events, correlation_id}, from, state) do
    # Check if we already have results
    case Map.get(state.results, correlation_id) do
      nil ->
        # No results yet, check if events are complete
        events = Map.get(state.events, correlation_id, [])

        case check_completion(events, state.event_types_needed) do
          :complete ->
            # Already complete, process immediately
            case state.process_events_fn.(events, state) do
              {:ok, result_events, new_state} ->
                # Store results and clean up
                new_state =
                  new_state
                  |> put_in([:results, correlation_id], result_events)
                  |> Map.update!(:events, &Map.delete(&1, correlation_id))
                  |> Map.update!(:waiters, &Map.delete(&1, correlation_id))

                {:reply, {:ok, result_events}, new_state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          :incomplete ->
            # Register waiter - store the full `from` tuple for reply_to
            waiters = Map.get(state.waiters, correlation_id, [])
            state = put_in(state.waiters[correlation_id], [from | waiters])

            # Don't reply yet - will reply when events complete
            {:noreply, state}
        end

      result_events ->
        # Results already available
        {:reply, {:ok, result_events}, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    # Catch-all for unexpected messages
    {:noreply, state}
  end

  ## Private Helpers

  defp check_completion(events, event_types_needed) do
    event_types_captured =
      events
      |> Enum.map(& &1.__struct__)
      |> MapSet.new()

    needed_set = MapSet.new(event_types_needed)

    if MapSet.subset?(needed_set, event_types_captured) do
      :complete
    else
      :incomplete
    end
  end

  @doc """
  Enables using this module in your own aggregator implementations.

  ## Example

      defmodule MyAggregator do
        use Mojentic.Agents.AsyncAggregatorAgent

        def start_link do
          AsyncAggregatorAgent.start_link(
            event_types_needed: [EventA, EventB],
            process_events_fn: &__MODULE__.process_events/2,
            name: __MODULE__
          )
        end

        def process_events(events, state) do
          # Custom processing logic
          {:ok, [result_event], state}
        end
      end

  """
  defmacro __using__(_opts) do
    quote do
      alias Mojentic.Agents.AsyncAggregatorAgent

      def start_link(opts), do: AsyncAggregatorAgent.start_link(opts)
      def receive_event(pid, event), do: AsyncAggregatorAgent.receive_event(pid, event)

      def wait_for_events(pid, correlation_id, opts \\ []),
        do: AsyncAggregatorAgent.wait_for_events(pid, correlation_id, opts)

      defoverridable start_link: 1
    end
  end
end
