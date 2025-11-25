#!/usr/bin/env elixir

# ReAct Pattern Example
#
# This example demonstrates a Reasoning and Acting (ReAct) loop where agents
# iteratively plan, decide, act, and summarize to answer user queries.
#
# The ReAct pattern consists of:
# 1. Thinking Agent - Creates plans
# 2. Decisioning Agent - Decides next actions
# 3. Tool Call Agent - Executes tools
# 4. Summarization Agent - Generates final answers

Mix.install([
  {:mojentic, path: Path.expand("../../mojentic-ex", __DIR__)}
])

defmodule ReactExample do
  @moduledoc """
  ReAct Pattern Example Implementation.

  Demonstrates the Reasoning and Acting (ReAct) loop using an event-driven
  agent system with async dispatching.
  """

  require Logger

  alias Mojentic.{AsyncDispatcher, Router}
  alias Mojentic.LLM.{Broker, Gateways.Ollama}

  alias Mojentic.Examples.React.Events.{
    InvokeThinking,
    InvokeDecisioning,
    InvokeToolCall,
    FinishAndSummarize,
    FailureOccurred
  }

  alias Mojentic.Examples.React.Models.CurrentContext

  # Agent wrapper modules that create brokers internally
  defmodule ThinkingAgentWrapper do
    @moduledoc false
    @behaviour Mojentic.Agents.BaseAsyncAgent

    alias Mojentic.Examples.React.ThinkingAgent
    alias Mojentic.LLM.{Broker, Gateways.Ollama}

    @impl true
    def receive_event_async(event) do
      broker = Broker.new("qwen3:8b", Ollama)
      ThinkingAgent.receive_event_async(broker, event)
    end
  end

  defmodule DecisioningAgentWrapper do
    @moduledoc false
    @behaviour Mojentic.Agents.BaseAsyncAgent

    alias Mojentic.Examples.React.DecisioningAgent
    alias Mojentic.LLM.{Broker, Gateways.Ollama}

    @impl true
    def receive_event_async(event) do
      broker = Broker.new("qwen3:8b", Ollama)
      DecisioningAgent.receive_event_async(broker, event)
    end
  end

  defmodule ToolCallAgentWrapper do
    @moduledoc false
    @behaviour Mojentic.Agents.BaseAsyncAgent

    alias Mojentic.Examples.React.ToolCallAgent

    @impl true
    def receive_event_async(event) do
      ToolCallAgent.receive_event_async(nil, event)
    end
  end

  defmodule SummarizationAgentWrapper do
    @moduledoc false
    @behaviour Mojentic.Agents.BaseAsyncAgent

    alias Mojentic.Examples.React.SummarizationAgent
    alias Mojentic.LLM.{Broker, Gateways.Ollama}

    @impl true
    def receive_event_async(event) do
      broker = Broker.new("qwen3:8b", Ollama)
      SummarizationAgent.receive_event_async(broker, event)
    end
  end

  defmodule OutputAgentWrapper do
    @moduledoc false
    @behaviour Mojentic.Agents.BaseAsyncAgent

    alias Mojentic.Examples.React.OutputAgent

    @impl true
    def receive_event_async(event) do
      OutputAgent.receive_event_async(nil, event)
    end
  end

  @doc """
  Runs the ReAct pattern example.
  """
  def run do
    # Create router - maps event types to agent handlers
    router =
      Router.new()
      |> Router.add_route(InvokeThinking, ThinkingAgentWrapper)
      |> Router.add_route(InvokeThinking, OutputAgentWrapper)
      |> Router.add_route(InvokeDecisioning, DecisioningAgentWrapper)
      |> Router.add_route(InvokeDecisioning, OutputAgentWrapper)
      |> Router.add_route(InvokeToolCall, ToolCallAgentWrapper)
      |> Router.add_route(InvokeToolCall, OutputAgentWrapper)
      |> Router.add_route(FinishAndSummarize, SummarizationAgentWrapper)
      |> Router.add_route(FinishAndSummarize, OutputAgentWrapper)
      |> Router.add_route(FailureOccurred, OutputAgentWrapper)

    # Start the async dispatcher
    {:ok, dispatcher} = AsyncDispatcher.start_link(router: router)

    # Create initial context
    initial_context = CurrentContext.new("What is the date next Friday?")

    # Start the ReAct loop
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("Starting ReAct Pattern Example")
    IO.puts(String.duplicate("=", 80))
    IO.puts("User Query: #{initial_context.user_query}")
    IO.puts(String.duplicate("=", 80) <> "\n")

    # Create and dispatch initial thinking event
    initial_event = %InvokeThinking{
      source: __MODULE__,
      context: initial_context
    }

    AsyncDispatcher.dispatch(dispatcher, initial_event)

    # Wait for processing to complete
    IO.puts("\nWaiting for ReAct loop to complete...")
    :ok = AsyncDispatcher.wait_for_empty_queue(dispatcher, timeout: 120_000)

    # Stop dispatcher
    AsyncDispatcher.stop(dispatcher)

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("ReAct Pattern Example Complete")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end
end

# Run the example
ReactExample.run()
