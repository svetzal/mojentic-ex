defmodule Mojentic.Agents.SimpleRecursiveAgent do
  @moduledoc """
  A simple recursive agent that uses events and async to solve problems.

  This agent provides a declarative event-driven approach to problem-solving.
  It will continue attempting to solve the problem until it either succeeds,
  fails explicitly, or reaches the maximum number of iterations.

  ## Architecture

  The agent uses three main components:

  1. **GoalState** - Tracks the problem-solving state through iterations
  2. **EventEmitter** - GenServer that manages event subscriptions and async dispatch
  3. **SimpleRecursiveAgent** - Orchestrates the problem-solving process

  ## Events

  The agent emits the following events during problem-solving:

  - `GoalSubmittedEvent` - When a problem is submitted
  - `IterationCompletedEvent` - After each iteration completes
  - `GoalAchievedEvent` - When the goal is successfully achieved
  - `GoalFailedEvent` - When the goal explicitly fails
  - `TimeoutEvent` - When the process times out

  ## Usage

      alias Mojentic.LLM.{Broker, Gateways.Ollama}
      alias Mojentic.LLM.Tools.DateResolver
      alias Mojentic.Agents.SimpleRecursiveAgent

      broker = Broker.new("qwen3:32b", Ollama)

      agent = SimpleRecursiveAgent.new(
        broker,
        tools: [DateResolver],
        max_iterations: 5
      )

      case SimpleRecursiveAgent.solve(agent, "What's the date next Friday?") do
        {:ok, result} -> IO.puts("Result: \#{result}")
        {:error, reason} -> IO.puts("Error: \#{inspect(reason)}")
      end

  ## Options

  - `:tools` - List of tool modules available to the LLM (default: [])
  - `:max_iterations` - Maximum number of iterations before giving up (default: 5)
  - `:system_prompt` - Custom system prompt (default: problem-solving assistant prompt)

  ## Completion Indicators

  The agent monitors responses for these keywords:
  - "DONE" (case-insensitive) - Task completed successfully
  - "FAIL" (case-insensitive) - Task cannot be completed
  """

  alias Mojentic.LLM.{Broker, ChatSession}

  require Logger

  # Goal state tracking
  defmodule GoalState do
    @moduledoc """
    Represents the state of a problem-solving process.
    """

    @type t :: %__MODULE__{
            goal: String.t(),
            iteration: non_neg_integer(),
            max_iterations: pos_integer(),
            solution: String.t() | nil,
            is_complete: boolean()
          }

    @enforce_keys [:goal]
    defstruct [
      :goal,
      iteration: 0,
      max_iterations: 5,
      solution: nil,
      is_complete: false
    ]
  end

  # Event definitions
  defmodule GoalSubmittedEvent do
    @moduledoc """
    Event triggered when a problem is submitted for solving.
    """
    @type t :: %__MODULE__{state: GoalState.t()}
    defstruct [:state]
  end

  defmodule IterationCompletedEvent do
    @moduledoc """
    Event triggered when an iteration of the problem-solving process is completed.
    """
    @type t :: %__MODULE__{state: GoalState.t(), response: String.t()}
    defstruct [:state, :response]
  end

  defmodule GoalAchievedEvent do
    @moduledoc """
    Event triggered when a problem is solved.
    """
    @type t :: %__MODULE__{state: GoalState.t()}
    defstruct [:state]
  end

  defmodule GoalFailedEvent do
    @moduledoc """
    Event triggered when a problem cannot be solved.
    """
    @type t :: %__MODULE__{state: GoalState.t()}
    defstruct [:state]
  end

  defmodule TimeoutEvent do
    @moduledoc """
    Event triggered when the problem-solving process times out.
    """
    @type t :: %__MODULE__{state: GoalState.t()}
    defstruct [:state]
  end

  # EventEmitter GenServer
  defmodule EventEmitter do
    @moduledoc """
    A GenServer-based event emitter that allows subscribing to and emitting events.

    Subscribers receive events asynchronously via spawned tasks.
    """
    use GenServer

    # Client API

    @doc """
    Starts the EventEmitter GenServer.
    """
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    @doc """
    Subscribes to an event type.

    Returns a reference that can be used to unsubscribe.

    ## Parameters

    - `pid` - The EventEmitter process
    - `event_type` - The event module to subscribe to
    - `callback` - Function to call when event is emitted

    ## Examples

        ref = EventEmitter.subscribe(emitter, GoalSubmittedEvent, fn event ->
          IO.inspect(event)
        end)

        EventEmitter.unsubscribe(emitter, ref)
    """
    @spec subscribe(pid(), module(), function()) :: reference()
    def subscribe(pid, event_type, callback) do
      GenServer.call(pid, {:subscribe, event_type, callback})
    end

    @doc """
    Unsubscribes from events using the reference returned by subscribe.
    """
    @spec unsubscribe(pid(), reference()) :: :ok
    def unsubscribe(pid, ref) do
      GenServer.call(pid, {:unsubscribe, ref})
    end

    @doc """
    Emits an event to all subscribers asynchronously.

    ## Parameters

    - `pid` - The EventEmitter process
    - `event` - The event struct to emit

    ## Examples

        EventEmitter.emit(emitter, %GoalSubmittedEvent{state: state})
    """
    @spec emit(pid(), struct()) :: :ok
    def emit(pid, event) do
      GenServer.cast(pid, {:emit, event})
    end

    # Server callbacks

    @impl true
    def init(:ok) do
      {:ok, %{subscribers: %{}}}
    end

    @impl true
    def handle_call({:subscribe, event_type, callback}, _from, state) do
      ref = make_ref()
      subscribers = Map.get(state.subscribers, event_type, [])
      new_subscribers = [{ref, callback} | subscribers]

      new_state = %{
        state
        | subscribers: Map.put(state.subscribers, event_type, new_subscribers)
      }

      {:reply, ref, new_state}
    end

    @impl true
    def handle_call({:unsubscribe, ref}, _from, state) do
      new_subscribers =
        Enum.reduce(state.subscribers, %{}, fn {event_type, callbacks}, acc ->
          filtered = Enum.reject(callbacks, fn {cb_ref, _cb} -> cb_ref == ref end)
          Map.put(acc, event_type, filtered)
        end)

      {:reply, :ok, %{state | subscribers: new_subscribers}}
    end

    @impl true
    def handle_cast({:emit, event}, state) do
      event_type = event.__struct__
      subscribers = Map.get(state.subscribers, event_type, [])

      # Call each subscriber asynchronously
      Enum.each(subscribers, fn {_ref, callback} ->
        Task.start(fn -> callback.(event) end)
      end)

      {:noreply, state}
    end
  end

  # Main agent structure
  @type t :: %__MODULE__{
          broker: Broker.t(),
          tools: [module()],
          max_iterations: pos_integer(),
          system_prompt: String.t(),
          emitter: pid()
        }

  @enforce_keys [:broker, :emitter]
  defstruct [
    :broker,
    :emitter,
    tools: [],
    max_iterations: 5,
    system_prompt: """
    You are a problem-solving assistant that can solve complex problems step by step.
    You analyze problems, break them down into smaller parts, and solve them systematically.
    If you cannot solve a problem completely in one step, you make progress and identify what to do next.
    """
  ]

  @default_system_prompt """
  You are a problem-solving assistant that can solve complex problems step by step.
  You analyze problems, break them down into smaller parts, and solve them systematically.
  If you cannot solve a problem completely in one step, you make progress and identify what to do next.
  """

  @doc """
  Creates a new SimpleRecursiveAgent.

  ## Parameters

  - `broker` - The LLM broker to use for generating responses
  - `opts` - Keyword list of options:
    - `:tools` - List of tool modules (default: [])
    - `:max_iterations` - Maximum iterations (default: 5)
    - `:system_prompt` - Custom system prompt (default: problem-solving prompt)

  ## Examples

      broker = Broker.new("qwen3:32b", Ollama)

      # With defaults
      agent = SimpleRecursiveAgent.new(broker)

      # With custom options
      agent = SimpleRecursiveAgent.new(broker,
        tools: [MyTool],
        max_iterations: 10,
        system_prompt: "You are a specialized assistant."
      )

  """
  @spec new(Broker.t(), keyword()) :: t()
  def new(broker, opts \\ []) do
    {:ok, emitter} = EventEmitter.start_link()

    %__MODULE__{
      broker: broker,
      emitter: emitter,
      tools: Keyword.get(opts, :tools, []),
      max_iterations: Keyword.get(opts, :max_iterations, 5),
      system_prompt: Keyword.get(opts, :system_prompt, @default_system_prompt)
    }
  end

  @doc """
  Solves a problem asynchronously using the recursive agent.

  This method runs the event-driven problem-solving process with a 300-second timeout.
  The agent will continue iterating until:
  - The task is completed successfully ("DONE")
  - The task fails explicitly ("FAIL")
  - The maximum number of iterations is reached
  - The process times out (300 seconds)

  ## Parameters

  - `agent` - The SimpleRecursiveAgent instance
  - `problem` - The problem or request to be solved

  ## Returns

  - `{:ok, solution}` - Success with the solution
  - `{:error, reason}` - Error during solving

  ## Examples

      {:ok, result} = SimpleRecursiveAgent.solve(agent, "Calculate 2+2")
      # => {:ok, "2+2 equals 4."}

      {:ok, result} = SimpleRecursiveAgent.solve(agent, "What's the weather tomorrow?")
      # Uses tools to gather info and answer

  """
  @spec solve(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def solve(agent, problem) do
    # Create the initial goal state
    state = %GoalState{goal: problem, max_iterations: agent.max_iterations}

    # Create a task to track completion
    parent = self()
    solution_ref = make_ref()

    # Set up event handlers
    EventEmitter.subscribe(agent.emitter, GoalSubmittedEvent, fn event ->
      handle_goal_submitted(agent, event)
    end)

    EventEmitter.subscribe(agent.emitter, IterationCompletedEvent, fn event ->
      handle_iteration_completed(agent, event)
    end)

    # Handle completion events by sending message to parent
    completion_handler = fn event ->
      send(parent, {solution_ref, event.state.solution})
    end

    EventEmitter.subscribe(agent.emitter, GoalAchievedEvent, completion_handler)
    EventEmitter.subscribe(agent.emitter, GoalFailedEvent, completion_handler)
    EventEmitter.subscribe(agent.emitter, TimeoutEvent, completion_handler)

    # Start the solving process
    EventEmitter.emit(agent.emitter, %GoalSubmittedEvent{state: state})

    # Wait for solution or timeout
    timeout_ms = 300_000

    receive do
      {^solution_ref, solution} when is_binary(solution) ->
        {:ok, solution}

      {^solution_ref, nil} ->
        {:error, :no_solution}
    after
      timeout_ms ->
        timeout_message = "Timeout: Could not solve the problem within 300 seconds."

        updated_state = %{
          state
          | solution: timeout_message,
            is_complete: true
        }

        EventEmitter.emit(agent.emitter, %TimeoutEvent{state: updated_state})
        {:ok, timeout_message}
    end
  end

  # Private event handlers

  defp handle_goal_submitted(agent, event) do
    # Start the first iteration
    process_iteration(agent, event.state)
  end

  defp handle_iteration_completed(agent, event) do
    state = event.state
    response = event.response
    response_lower = String.downcase(response)

    cond do
      # Check if the task failed
      # Match "FAIL" as a complete word (not in "failed", "unfailing", etc.)
      # Allow variations like "FAIL", "fail", "Fail"
      String.contains?(response_lower, "fail") &&
          Regex.match?(~r/\bfail\b/, response_lower) ->
        updated_state = %{
          state
          | solution: "Failed to solve after #{state.iteration} iterations:\n#{response}",
            is_complete: true
        }

        EventEmitter.emit(agent.emitter, %GoalFailedEvent{state: updated_state})

      # Check if the task succeeded
      # Match "DONE" as a complete word (not in "abandoned", "undone", etc.)
      # Allow variations like "DONE", "done", "Done"
      String.contains?(response_lower, "done") &&
          Regex.match?(~r/\bdone\b/, response_lower) ->
        updated_state = %{
          state
          | solution: response,
            is_complete: true
        }

        EventEmitter.emit(agent.emitter, %GoalAchievedEvent{state: updated_state})

      # Check if we've reached max iterations
      state.iteration >= state.max_iterations ->
        updated_state = %{
          state
          | solution: "Best solution after #{state.max_iterations} iterations:\n#{response}",
            is_complete: true
        }

        EventEmitter.emit(agent.emitter, %GoalAchievedEvent{state: updated_state})

      # Continue with next iteration
      true ->
        process_iteration(agent, state)
    end
  end

  defp process_iteration(agent, state) do
    # Increment iteration counter
    updated_state = %{state | iteration: state.iteration + 1}

    # Generate prompt for this iteration
    prompt = """
    Given the user request:
    #{state.goal}

    Use the tools at your disposal to act on their request.
    You may wish to create a step-by-step plan for more complicated requests.

    If you cannot provide an answer, say only "FAIL".
    If you have the answer, say only "DONE".
    """

    # Create a task to generate response asynchronously
    Task.start(fn ->
      case generate_response(agent, prompt) do
        {:ok, response} ->
          EventEmitter.emit(
            agent.emitter,
            %IterationCompletedEvent{state: updated_state, response: response}
          )

        {:error, reason} ->
          Logger.error("Error generating response: #{inspect(reason)}")

          error_state = %{
            updated_state
            | solution: "Error: #{inspect(reason)}",
              is_complete: true
          }

          EventEmitter.emit(agent.emitter, %GoalFailedEvent{state: error_state})
      end
    end)
  end

  defp generate_response(agent, prompt) do
    # Create a chat session for this request
    chat =
      ChatSession.new(agent.broker,
        system_prompt: agent.system_prompt,
        tools: agent.tools
      )

    case ChatSession.send(chat, prompt) do
      {:ok, response, _updated_session} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
