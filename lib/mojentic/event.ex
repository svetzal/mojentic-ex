defmodule Mojentic.Event do
  @moduledoc """
  Base event structure for agent communication.

  Events are the primary mechanism for communication between agents in the
  Mojentic agent system. Each event carries information about its source,
  a correlation ID for tracking related events, and any domain-specific data.

  ## Fields

  - `source` - The module of the agent that created this event
  - `correlation_id` - UUID for tracking related events in a workflow
  - Additional fields defined by specific event types

  ## Examples

      defmodule MyApp.Events.QuestionEvent do
        use Mojentic.Event

        @type t :: %__MODULE__{
          source: module(),
          correlation_id: String.t() | nil,
          question: String.t()
        }

        defstruct [:source, :correlation_id, :question]
      end

      event = %MyApp.Events.QuestionEvent{
        source: MyApp.QuestionAgent,
        correlation_id: UUID.uuid4(),
        question: "What is Elixir?"
      }

  """

  @type t :: %{
          __struct__: module(),
          source: module(),
          correlation_id: String.t() | nil
        }

  @doc """
  Defines a module as an event type with required base fields.

  When you `use Mojentic.Event`, your module gets:
  - Base fields: `source` and `correlation_id`
  - These fields must be included in your struct definition

  ## Example

      defmodule MyEvent do
        use Mojentic.Event

        defstruct [:source, :correlation_id, :custom_field]
      end

  """
  defmacro __using__(_opts) do
    quote do
      # Event marker - modules can define their own @type t
    end
  end

  @doc """
  Creates a new event with an auto-generated correlation ID if not provided.

  ## Parameters

  - `module` - The event module to create
  - `attrs` - Keyword list or map of attributes

  ## Examples

      Mojentic.Event.new(QuestionEvent, source: MyAgent, question: "Hello?")
      #=> %QuestionEvent{source: MyAgent, correlation_id: "...", question: "Hello?"}

  """
  def new(module, attrs) when is_list(attrs) do
    attrs = Keyword.put_new_lazy(attrs, :correlation_id, &UUID.uuid4/0)
    struct!(module, attrs)
  end

  def new(module, attrs) when is_map(attrs) do
    attrs = Map.put_new_lazy(attrs, :correlation_id, &UUID.uuid4/0)
    struct!(module, attrs)
  end
end

defmodule Mojentic.Events.TerminateEvent do
  @moduledoc """
  Special event that signals the dispatcher to stop processing.

  When a `TerminateEvent` is dispatched, the async dispatcher will gracefully
  shut down after processing any remaining events in the queue.

  ## Examples

      terminate_event = %Mojentic.Events.TerminateEvent{
        source: MyAgent
      }

      AsyncDispatcher.dispatch(dispatcher, terminate_event)

  """
  use Mojentic.Event

  @type t :: %__MODULE__{
          source: module(),
          correlation_id: String.t() | nil
        }

  defstruct [:source, :correlation_id]
end
