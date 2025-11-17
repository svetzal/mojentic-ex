#!/usr/bin/env elixir

# Example script demonstrating how to use the AsyncDispatcher with async LLM agents.
#
# This script shows how to create and use asynchronous LLM agents with the AsyncDispatcher.
# It demonstrates a workflow where:
#   1. QuestionEvent → FactCheckerAgent (async LLM) → FactCheckEvent
#   2. QuestionEvent → AnswerGeneratorAgent (async LLM) → AnswerEvent
#   3. FactCheckEvent + AnswerEvent → FinalAnswerAgent (aggregator) → FinalAnswerEvent

Mix.install([
  {:mojentic, path: Path.expand("..", __DIR__)}
])

defmodule AsyncLLMExample do
  @moduledoc """
  Example demonstrating async LLM agents with event aggregation.
  """

  require Logger

  alias Mojentic.{AsyncDispatcher, Event, Router}
  alias Mojentic.Agents.{AsyncAggregatorAgent, AsyncLLMAgent, BaseAsyncAgent}
  alias Mojentic.LLM.{Broker, Message}
  alias Mojentic.LLM.Gateways.Ollama

  # ============================================================================
  # Event Definitions
  # ============================================================================

  defmodule QuestionEvent do
    @moduledoc "Event containing a question to be answered"
    use Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            question: String.t()
          }

    defstruct [:source, :correlation_id, :question]
  end

  defmodule FactCheckEvent do
    @moduledoc "Event containing facts related to a question"
    use Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            question: String.t(),
            facts: [String.t()]
          }

    defstruct [:source, :correlation_id, :question, :facts]
  end

  defmodule AnswerEvent do
    @moduledoc "Event containing an answer to a question"
    use Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            question: String.t(),
            answer: String.t(),
            confidence: float()
          }

    defstruct [:source, :correlation_id, :question, :answer, :confidence]
  end

  defmodule FinalAnswerEvent do
    @moduledoc "Event containing the final answer with facts"
    use Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            question: String.t(),
            answer: String.t(),
            facts: [String.t()],
            confidence: float()
          }

    defstruct [:source, :correlation_id, :question, :answer, :facts, :confidence]
  end

  # ============================================================================
  # Agent Definitions
  # ============================================================================

  defmodule FactCheckerAgent do
    @moduledoc """
    An async agent that checks facts related to a question.
    """

    @behaviour BaseAsyncAgent

    def new(broker) do
      AsyncLLMAgent.new(
        broker: broker,
        behaviour: "You are a fact-checking assistant. Your job is to provide relevant facts about a question.",
        response_model: %{
          "type" => "object",
          "required" => ["facts"],
          "properties" => %{
            "facts" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "List of relevant facts"
            }
          }
        }
      )
    end

    @impl true
    def receive_event_async(%QuestionEvent{question: question} = event) do
      IO.puts("FactCheckerAgent processing question: #{question}")

      broker = Broker.new("qwen2.5:7b", Ollama)
      agent = new(broker)

      prompt = "Please provide relevant facts about the following question: #{question}"

      case AsyncLLMAgent.generate_response(agent, prompt) do
        {:ok, %{"facts" => facts}} ->
          fact_event = %FactCheckEvent{
            source: __MODULE__,
            correlation_id: event.correlation_id,
            question: question,
            facts: facts
          }

          IO.puts("FactCheckerAgent generated #{length(facts)} facts")
          {:ok, [fact_event]}

        {:error, reason} ->
          Logger.error("FactCheckerAgent failed: #{inspect(reason)}")
          {:error, reason}
      end
    end

    def receive_event_async(_event), do: {:ok, []}
  end

  defmodule AnswerGeneratorAgent do
    @moduledoc """
    An async agent that generates an answer to a question.
    """

    @behaviour BaseAsyncAgent

    def new(broker) do
      AsyncLLMAgent.new(
        broker: broker,
        behaviour: "You are a question-answering assistant. Your job is to provide accurate answers to questions.",
        response_model: %{
          "type" => "object",
          "required" => ["answer", "confidence"],
          "properties" => %{
            "answer" => %{
              "type" => "string",
              "description" => "The answer to the question"
            },
            "confidence" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "description" => "Confidence level (0-1)"
            }
          }
        }
      )
    end

    @impl true
    def receive_event_async(%QuestionEvent{question: question} = event) do
      IO.puts("AnswerGeneratorAgent processing question: #{question}")

      broker = Broker.new("qwen2.5:7b", Ollama)
      agent = new(broker)

      prompt = "Please answer the following question: #{question}"

      case AsyncLLMAgent.generate_response(agent, prompt) do
        {:ok, %{"answer" => answer, "confidence" => confidence}} ->
          answer_event = %AnswerEvent{
            source: __MODULE__,
            correlation_id: event.correlation_id,
            question: question,
            answer: answer,
            confidence: confidence
          }

          IO.puts("AnswerGeneratorAgent generated answer with confidence #{confidence}")
          {:ok, [answer_event]}

        {:error, reason} ->
          Logger.error("AnswerGeneratorAgent failed: #{inspect(reason)}")
          {:error, reason}
      end
    end

    def receive_event_async(_event), do: {:ok, []}
  end

  defmodule FinalAnswerAgent do
    @moduledoc """
    An aggregator agent that combines facts and answers to produce a final answer.
    """

    def start_link do
      AsyncAggregatorAgent.start_link(
        event_types_needed: [FactCheckEvent, AnswerEvent],
        process_events_fn: &__MODULE__.process_events/2,
        name: __MODULE__
      )
    end

    def process_events(events, state) do
      IO.puts("FinalAnswerAgent processing #{length(events)} events")

      fact_check_event = Enum.find(events, &match?(%FactCheckEvent{}, &1))
      answer_event = Enum.find(events, &match?(%AnswerEvent{}, &1))

      if fact_check_event && answer_event do
        IO.puts("FinalAnswerAgent has both FactCheckEvent and AnswerEvent")

        # Adjust confidence based on facts
        confidence = answer_event.confidence

        confidence =
          if length(fact_check_event.facts) > 0 do
            # Increase confidence if we have facts
            min(1.0, confidence + 0.1)
          else
            confidence
          end

        final_event = %FinalAnswerEvent{
          source: __MODULE__,
          correlation_id: fact_check_event.correlation_id,
          question: fact_check_event.question,
          answer: answer_event.answer,
          facts: fact_check_event.facts,
          confidence: confidence
        }

        IO.puts("FinalAnswerAgent created FinalAnswerEvent")
        {:ok, [final_event], state}
      else
        IO.puts("FinalAnswerAgent missing required events")
        {:ok, [], state}
      end
    end

    def get_final_answer(correlation_id, timeout \\ 30_000) do
      AsyncAggregatorAgent.wait_for_events(__MODULE__, correlation_id, timeout: timeout)
    end
  end

  # ============================================================================
  # Main Example
  # ============================================================================

  def run do
    IO.puts("\n=== Async LLM Example ===\n")

    # Create router and register agents
    IO.puts("Setting up router and agents...")

    {:ok, final_answer_agent} = FinalAnswerAgent.start_link()

    router =
      Router.new()
      |> Router.add_route(QuestionEvent, FactCheckerAgent)
      |> Router.add_route(QuestionEvent, AnswerGeneratorAgent)
      |> Router.add_route(FactCheckEvent, final_answer_agent)
      |> Router.add_route(AnswerEvent, final_answer_agent)

    # Create and start the dispatcher
    IO.puts("Starting dispatcher...")
    {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

    # Create a question event
    question = "What is the capital of France?"
    IO.puts("\nAsking question: #{question}\n")

    event = %QuestionEvent{
      source: __MODULE__,
      correlation_id: UUID.uuid4(),
      question: question
    }

    # Dispatch the event
    IO.puts("Dispatching question event...")
    AsyncDispatcher.dispatch(dispatcher, event)

    # Wait a moment for processing to start
    Process.sleep(100)

    # Wait for the final answer from the FinalAnswerAgent
    IO.puts("Waiting for final answer from FinalAnswerAgent...")

    case FinalAnswerAgent.get_final_answer(event.correlation_id) do
      {:ok, [%FinalAnswerEvent{} = final_answer | _]} ->
        IO.puts("\n=== Final Answer ===")
        IO.puts("Question: #{final_answer.question}")
        IO.puts("Answer: #{final_answer.answer}")
        IO.puts("Confidence: #{final_answer.confidence}")
        IO.puts("\nFacts:")

        Enum.each(final_answer.facts, fn fact ->
          IO.puts("  - #{fact}")
        end)

      {:error, :timeout} ->
        IO.puts("\nTimeout waiting for final answer")

      other ->
        IO.puts("\nUnexpected result: #{inspect(other)}")
    end

    # Clean up
    IO.puts("\n\nStopping dispatcher...")
    AsyncDispatcher.stop(dispatcher)
    GenServer.stop(final_answer_agent)

    IO.puts("Done!\n")
  end
end

# Run the example
AsyncLLMExample.run()
