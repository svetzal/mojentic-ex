defmodule Mojentic.AsyncDispatcher do
  @moduledoc """
  GenServer-based async event dispatcher for the agent system.

  The AsyncDispatcher manages event routing between agents in an asynchronous,
  non-blocking manner. It maintains an event queue (FIFO) and processes events
  by routing them through a `Mojentic.Router` to the appropriate agents.

  ## Features

  - **Event Queue** - FIFO queue using `:queue` module
  - **Async Processing** - Non-blocking event handling via Task and GenServer
  - **Mixed Agent Support** - Handles both sync and async agents
  - **Graceful Shutdown** - Stop via `TerminateEvent` or explicit `stop/1`
  - **Queue Monitoring** - Wait for empty queue with `wait_for_empty_queue/2`

  ## Architecture

      ┌─────────────┐
      │  Dispatcher │
      │   (GenServer) │
      └──────┬──────┘
             │ Event Queue
             │ [:queue]
             │
             ├─→ Router ─→ Agent1 ──→ [New Events]
             │            ↓
             └─→ Router ─→ Agent2 ──→ [New Events]

  ## State Structure

      %{
        router: %Router{},
        event_queue: :queue.queue(),
        processing: boolean(),
        batch_size: integer()
      }

  ## Usage

      # Create router
      router = Router.new()
      |> Router.add_route(QuestionEvent, fact_checker)
      |> Router.add_route(QuestionEvent, answer_generator)

      # Start dispatcher
      {:ok, pid} = AsyncDispatcher.start_link(router: router)

      # Dispatch events
      event = %QuestionEvent{source: MyApp, question: "What is Elixir?"}
      AsyncDispatcher.dispatch(pid, event)

      # Wait for queue to empty
      :ok = AsyncDispatcher.wait_for_empty_queue(pid, timeout: 10_000)

      # Stop dispatcher
      AsyncDispatcher.stop(pid)

  ## Examples

      # Full workflow
      router = Router.new()
      |> Router.add_route(QuestionEvent, fact_checker_pid)
      |> Router.add_route(FactCheckEvent, aggregator_pid)

      {:ok, dispatcher} = AsyncDispatcher.start_link(
        router: router,
        batch_size: 10
      )

      question = %QuestionEvent{
        source: MyApp,
        question: "What is the capital of France?"
      }

      AsyncDispatcher.dispatch(dispatcher, question)
      AsyncDispatcher.wait_for_empty_queue(dispatcher)
      AsyncDispatcher.stop(dispatcher)

  """

  use GenServer

  alias Mojentic.Router
  alias Mojentic.Events.TerminateEvent

  require Logger

  @type state :: %{
          router: Router.t(),
          event_queue: :queue.queue(),
          processing: boolean(),
          batch_size: non_neg_integer(),
          pending_tasks: non_neg_integer()
        }

  @default_batch_size 5
  @poll_interval 100

  ## Client API

  @doc """
  Starts the async dispatcher as a linked process.

  ## Options

  - `:router` - Router instance for event routing (required)
  - `:batch_size` - Number of events to process per batch (default: 5)
  - `:name` - Process registration name (optional)

  ## Examples

      {:ok, pid} = AsyncDispatcher.start_link(router: router)

      {:ok, pid} = AsyncDispatcher.start_link(
        router: router,
        batch_size: 10,
        name: MyDispatcher
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
  Dispatches an event to the event queue.

  The event will be assigned a correlation_id if it doesn't have one.
  Events are processed in FIFO order by the dispatcher loop.

  ## Parameters

  - `pid` - The dispatcher process
  - `event` - The event to dispatch

  ## Examples

      event = %QuestionEvent{source: MyApp, question: "Hello?"}
      AsyncDispatcher.dispatch(dispatcher, event)

  """
  def dispatch(pid, event) do
    GenServer.cast(pid, {:dispatch, event})
  end

  @doc """
  Stops the dispatcher gracefully.

  Waits for the current batch to complete before shutting down.

  ## Parameters

  - `pid` - The dispatcher process
  - `timeout` - Maximum time to wait for shutdown (default: 5000ms)

  ## Examples

      AsyncDispatcher.stop(dispatcher)
      AsyncDispatcher.stop(dispatcher, 10_000)

  """
  def stop(pid, timeout \\ 5000) do
    GenServer.stop(pid, :normal, timeout)
  end

  @doc """
  Waits for the event queue to be empty.

  This is useful for testing or ensuring all events have been processed
  before continuing.

  ## Parameters

  - `pid` - The dispatcher process
  - `opts` - Keyword list with:
    - `:timeout` - Maximum wait time in milliseconds (default: 5000)

  ## Returns

  - `:ok` - Queue is empty
  - `{:error, :timeout}` - Timeout reached with events still in queue

  ## Examples

      :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher)

      case AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 10_000) do
        :ok -> IO.puts("All events processed")
        {:error, :timeout} -> IO.puts("Timed out waiting")
      end

  """
  def wait_for_empty_queue(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    start_time = System.monotonic_time(:millisecond)

    wait_loop(pid, start_time, timeout)
  end

  defp wait_loop(pid, start_time, timeout) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= timeout do
      {:error, :timeout}
    else
      case get_queue_size(pid) do
        0 ->
          :ok

        _size ->
          Process.sleep(100)
          wait_loop(pid, start_time, timeout)
      end
    end
  end

  @doc """
  Gets the current size of the event queue.

  ## Examples

      size = AsyncDispatcher.get_queue_size(dispatcher)

  """
  def get_queue_size(pid) do
    GenServer.call(pid, :get_queue_size)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    router = Keyword.fetch!(opts, :router)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    state = %{
      router: router,
      event_queue: :queue.new(),
      processing: false,
      batch_size: batch_size,
      pending_tasks: 0
    }

    # Start processing loop
    schedule_processing()

    {:ok, state}
  end

  @impl true
  def handle_cast({:dispatch, event}, state) do
    # Ensure event has correlation_id
    event =
      if is_nil(event.correlation_id) do
        %{event | correlation_id: UUID.uuid4()}
      else
        event
      end

    # Add to queue
    queue = :queue.in(event, state.event_queue)
    state = %{state | event_queue: queue}

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_queue_size, _from, state) do
    size = :queue.len(state.event_queue) + state.pending_tasks
    {:reply, size, state}
  end

  @impl true
  def handle_info(:process_events, state) do
    state = process_batch(state)
    schedule_processing()
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_result, correlation_id, result}, state) do
    Logger.debug("Received agent result for #{correlation_id}: #{inspect(result)}")

    # Decrement pending_tasks counter
    state = %{state | pending_tasks: max(0, state.pending_tasks - 1)}

    case result do
      {:ok, events} ->
        # Dispatch resulting events
        state =
          Enum.reduce(events, state, fn event, acc_state ->
            if match?(%TerminateEvent{}, event) do
              Logger.info("Received TerminateEvent, stopping dispatcher")
              send(self(), :stop)
              acc_state
            else
              queue = :queue.in(event, acc_state.event_queue)
              %{acc_state | event_queue: queue}
            end
          end)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Agent processing failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:stop, state) do
    {:stop, :normal, state}
  end

  ## Private Helpers

  defp schedule_processing do
    Process.send_after(self(), :process_events, @poll_interval)
  end

  defp process_batch(state) do
    if state.processing do
      state
    else
      state = %{state | processing: true}
      state = do_process_batch(state, state.batch_size)
      %{state | processing: false}
    end
  end

  defp do_process_batch(state, 0), do: state

  defp do_process_batch(state, remaining) do
    case :queue.out(state.event_queue) do
      {{:value, event}, new_queue} ->
        state = %{state | event_queue: new_queue}

        # Check for TerminateEvent
        if match?(%TerminateEvent{}, event) do
          Logger.info("Received TerminateEvent, stopping dispatcher")
          send(self(), :stop)
          state
        else
          # Route event to agents
          agents = Router.get_agents(state.router, event)

          Logger.debug(
            "Processing event #{inspect(event.__struct__)} for #{length(agents)} agents"
          )

          # Process each agent and increment pending_tasks counter
          state = %{state | pending_tasks: state.pending_tasks + length(agents)}

          Enum.each(agents, fn agent ->
            process_agent(agent, event)
          end)

          do_process_batch(state, remaining - 1)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp process_agent(agent, event) when is_pid(agent) do
    # Agent is a GenServer (like AsyncAggregatorAgent)
    parent = self()

    Task.start(fn ->
      result =
        try do
          GenServer.call(agent, {:receive_event, event}, :infinity)
        catch
          :exit, reason ->
            Logger.error("Agent call failed: #{inspect(reason)}")
            {:error, reason}
        end

      send(parent, {:agent_result, event.correlation_id, result})
    end)
  end

  defp process_agent(agent, event) when is_atom(agent) do
    # Agent is a module implementing BaseAsyncAgent behaviour
    parent = self()

    Task.start(fn ->
      result =
        try do
          agent.receive_event_async(event)
        catch
          :error, reason ->
            {:error, reason}
        end

      send(parent, {:agent_result, event.correlation_id, result})
    end)
  end

  defp process_agent(agent, event) do
    Logger.warning("Unknown agent type: #{inspect(agent)}, event: #{inspect(event)}")
  end
end
