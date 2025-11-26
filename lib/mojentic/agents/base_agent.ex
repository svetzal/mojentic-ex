defmodule Mojentic.Agents.BaseAgent do
  @moduledoc """
  Behaviour for synchronous agents that process events.

  Synchronous agents implement the `receive_event/1` callback to process
  incoming events and return a list of new events. This is the simplest
  agent interface, suitable for agents that don't need to perform async
  operations.

  For agents that need to perform I/O, LLM calls, or other async operations,
  use `Mojentic.Agents.BaseAsyncAgent` instead.

  ## Callbacks

  - `receive_event/1` - Processes an event and returns new events

  ## Examples

      defmodule MyAgent do
        @behaviour Mojentic.Agents.BaseAgent

        @impl true
        def receive_event(event) do
          # Process event synchronously
          new_event = %MyEvent{
            source: __MODULE__,
            correlation_id: event.correlation_id,
            data: process(event.data)
          }
          [new_event]
        end
      end

  ## Default Implementation

  If you want a default no-op implementation, you can use the `__using__` macro:

      defmodule MyAgent do
        use Mojentic.Agents.BaseAgent

        # Override receive_event/1 as needed
      end

  """

  alias Mojentic.Event

  @doc """
  Receives and processes an event synchronously.

  This callback is invoked when an event is routed to this agent.
  The agent should process the event and return a list of new events
  to be dispatched, or an empty list if no further events are needed.

  ## Parameters

  - `event` - The event to process (implements `Mojentic.Event`)

  ## Returns

  - `[Event.t()]` - List of new events to dispatch (can be empty)

  ## Examples

      def receive_event(%QuestionEvent{question: question} = event) do
        answer = compute_answer(question)
        [%AnswerEvent{
          source: __MODULE__,
          correlation_id: event.correlation_id,
          answer: answer
        }]
      end

      # Return empty list when no response is needed
      def receive_event(_event) do
        []
      end

  """
  @callback receive_event(event :: Event.t()) :: [Event.t()]

  @doc """
  Allows using `BaseAgent` with default implementation.

  When you `use Mojentic.Agents.BaseAgent`, a default implementation
  of `receive_event/1` is provided that returns an empty list.

  ## Example

      defmodule MyAgent do
        use Mojentic.Agents.BaseAgent

        # Default receive_event/1 returns []
        # Override if you need custom behavior:
        #
        # @impl true
        # def receive_event(event) do
        #   # Your implementation
        # end
      end

  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Mojentic.Agents.BaseAgent

      @impl true
      def receive_event(_event) do
        []
      end

      defoverridable receive_event: 1
    end
  end
end
