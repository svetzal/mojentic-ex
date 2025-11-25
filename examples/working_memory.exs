#!/usr/bin/env elixir

# Example demonstrating SharedWorkingMemory with agent communication.
#
# For comprehensive documentation on the working memory pattern, see:
# guides/working_memory.md
#
# This example shows how agents can:
# 1. Access shared working memory for context
# 2. Learn new information from conversations
# 3. Update memory with learned facts
# 4. Coordinate via event-driven architecture
#
# The workflow:
# 1. RequestEvent → RequestAgent (processes with memory) → ResponseEvent
# 2. ResponseEvent → OutputAgent (displays result)

Mix.install([
  {:mojentic, path: Path.expand("..", __DIR__)}
])

defmodule WorkingMemoryExample do
  @moduledoc """
  Demonstrates SharedWorkingMemory usage with event-driven agents.
  """

  require Logger

  alias Mojentic.{AsyncDispatcher, Event, Router}
  alias Mojentic.Context.SharedWorkingMemory
  alias Mojentic.Agents.BaseLLMAgentWithMemory
  alias Mojentic.LLM.Broker
  alias Mojentic.LLM.Gateways.Ollama

  # ============================================================================
  # Event Definitions
  # ============================================================================

  defmodule RequestEvent do
    @moduledoc "User request event"
    use Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            text: String.t()
          }

    defstruct [:source, :correlation_id, :text]
  end

  defmodule ResponseEvent do
    @moduledoc "Agent response event with memory"
    use Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            text: String.t(),
            memory: map()
          }

    defstruct [:source, :correlation_id, :text, :memory]
  end

  # ============================================================================
  # Agent Definitions
  # ============================================================================

  defmodule RequestAgent do
    @moduledoc """
    Processes requests using shared working memory.

    This agent answers questions using what it knows from memory and
    learns new information to add back to memory.
    """

    use GenServer

    alias Mojentic.Agents.BaseLLMAgentWithMemory
    alias Mojentic.Context.SharedWorkingMemory

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts) do
      broker = Keyword.fetch!(opts, :broker)
      memory = Keyword.fetch!(opts, :memory)

      agent =
        BaseLLMAgentWithMemory.new(
          broker: broker,
          memory: memory,
          behaviour:
            "You are a helpful assistant, and you like to make note of new things that you learn.",
          instructions: "Answer the user's question, use what you know, and what you remember.",
          response_model: %{
            "type" => "object",
            "required" => ["text"],
            "properties" => %{
              "text" => %{
                "type" => "string",
                "description" => "Your response to the user"
              }
            }
          }
        )

      {:ok, %{agent: agent}}
    end

    @impl true
    def handle_call({:receive_event, %RequestEvent{text: text} = event}, _from, state) do
      Logger.info("RequestAgent processing: #{text}")

      case BaseLLMAgentWithMemory.generate_response_with_memory(state.agent, text) do
        {:ok, %{"text" => response_text}, updated_memory} ->
          # Update agent's memory reference
          agent = BaseLLMAgentWithMemory.update_memory(state.agent, updated_memory)

          response_event = %ResponseEvent{
            source: __MODULE__,
            correlation_id: event.correlation_id,
            text: response_text,
            memory: SharedWorkingMemory.get_working_memory(updated_memory)
          }

          Logger.info("RequestAgent generated response")
          {:reply, {:ok, [response_event]}, %{state | agent: agent}}

        {:error, reason} = error ->
          Logger.error("RequestAgent failed: #{inspect(reason)}")
          {:reply, error, state}
      end
    end

    def handle_call({:receive_event, _event}, _from, state) do
      {:reply, {:ok, []}, state}
    end
  end

  defmodule OutputAgent do
    @moduledoc """
    Displays events for debugging and observability.

    This agent logs all events it receives without producing new events.
    """

    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end

    @impl true
    def handle_call({:receive_event, %RequestEvent{text: text}}, _from, state) do
      IO.puts("\n┌─── Request ───────────────────────────────────")
      IO.puts("│ #{text}")
      IO.puts("└───────────────────────────────────────────────\n")
      {:reply, {:ok, []}, state}
    end

    def handle_call({:receive_event, %ResponseEvent{text: text, memory: memory}}, _from, state) do
      IO.puts("\n┌─── Response ──────────────────────────────────")
      IO.puts("│ #{text}")
      IO.puts("│")
      IO.puts("│ Updated Memory:")

      memory_json = Jason.encode!(memory, pretty: true)

      memory_json
      |> String.split("\n")
      |> Enum.each(fn line -> IO.puts("│   #{line}") end)

      IO.puts("└───────────────────────────────────────────────\n")
      {:reply, {:ok, []}, state}
    end

    def handle_call({:receive_event, _event}, _from, state) do
      {:reply, {:ok, []}, state}
    end
  end

  # ============================================================================
  # Main Example
  # ============================================================================

  def run do
    IO.puts("\n╔═══════════════════════════════════════════════╗")
    IO.puts("║   Working Memory Example                      ║")
    IO.puts("╚═══════════════════════════════════════════════╝\n")

    # Initialize shared working memory with user data
    memory =
      SharedWorkingMemory.new(%{
        "User" => %{
          "name" => "Stacey",
          "age" => 56
        }
      })

    IO.puts("Initial Memory:")
    memory_json = Jason.encode!(SharedWorkingMemory.get_working_memory(memory), pretty: true)
    IO.puts(memory_json)

    # Create LLM broker
    IO.puts("\nCreating LLM broker...")
    broker = Broker.new("qwen2.5:7b", Ollama)

    # Start agents
    IO.puts("Starting agents...")
    {:ok, request_agent} = RequestAgent.start_link(broker: broker, memory: memory)
    {:ok, output_agent} = OutputAgent.start_link([])

    # Create router
    router =
      Router.new()
      |> Router.add_route(RequestEvent, request_agent)
      |> Router.add_route(RequestEvent, output_agent)
      |> Router.add_route(ResponseEvent, output_agent)

    # Start dispatcher
    IO.puts("Starting dispatcher...")
    {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

    # Create and dispatch request event
    request_text =
      "What is my name, and how old am I? And, did you know I have a dog named Boomer, and two cats named Spot and Beau?"

    event = %RequestEvent{
      source: __MODULE__,
      text: request_text
    }

    IO.puts("\nDispatching request event...\n")
    AsyncDispatcher.dispatch(dispatcher, event)

    # Wait for processing to complete
    IO.puts("Waiting for processing...")

    case AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 60_000) do
      :ok ->
        IO.puts("\n✓ All events processed successfully")

      {:error, :timeout} ->
        IO.puts("\n✗ Timeout waiting for events to complete")
    end

    # Clean up
    IO.puts("\nCleaning up...")
    AsyncDispatcher.stop(dispatcher)
    GenServer.stop(request_agent)
    GenServer.stop(output_agent)

    IO.puts("\n╔═══════════════════════════════════════════════╗")
    IO.puts("║   Example Complete                            ║")
    IO.puts("╚═══════════════════════════════════════════════╝\n")
  end
end

# Run the example
WorkingMemoryExample.run()
