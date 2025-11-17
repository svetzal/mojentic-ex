defmodule Mojentic.Agents.BaseAsyncAgent do
  @moduledoc """
  Behaviour for asynchronous agents that process events.

  Async agents implement the `receive_event_async/1` callback to process
  incoming events asynchronously. This allows agents to perform I/O operations,
  call LLMs, or execute long-running tasks without blocking the dispatcher.

  The key difference from synchronous agents is that async agents return
  `{:ok, events}` or `{:error, reason}` tuples, and the dispatcher awaits
  their completion using OTP patterns (typically via GenServer or Task).

  ## Callbacks

  - `receive_event_async/1` - Processes an event and returns new events

  ## Examples

      defmodule MyAsyncAgent do
        @behaviour Mojentic.Agents.BaseAsyncAgent

        @impl true
        def receive_event_async(event) do
          # Process event asynchronously
          case process(event) do
            {:ok, result} ->
              new_event = %MyEvent{
                source: __MODULE__,
                correlation_id: event.correlation_id,
                data: result
              }
              {:ok, [new_event]}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end

  """

  alias Mojentic.Event

  @doc """
  Receives and processes an event asynchronously.

  This callback is invoked by the async dispatcher when an event is routed
  to this agent. The agent should process the event and return a list of
  new events to be dispatched, or an empty list if no further events are needed.

  ## Parameters

  - `event` - The event to process (implements `Mojentic.Event`)

  ## Returns

  - `{:ok, [Event.t()]}` - Successfully processed, returns new events
  - `{:error, term()}` - Processing failed with a reason

  ## Examples

      def receive_event_async(%QuestionEvent{question: question} = event) do
        answer = generate_answer(question)
        new_event = %AnswerEvent{
          source: __MODULE__,
          correlation_id: event.correlation_id,
          answer: answer
        }
        {:ok, [new_event]}
      end

  """
  @callback receive_event_async(event :: Event.t()) ::
              {:ok, [Event.t()]} | {:error, term()}
end
