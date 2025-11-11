defmodule Mojentic do
  @moduledoc """
  Mojentic is an LLM integration framework for Elixir.

  Mojentic provides a clean abstraction over multiple LLM providers
  (OpenAI, Ollama, Anthropic) with tool support, structured output
  generation, and an event-driven agent system.

  ## Features

  - 🔌 **Multiple Providers**: OpenAI, Ollama, Anthropic (Ollama implemented in Phase 1)
  - 🛠️ **Tool Support**: Allow LLMs to call functions
  - 📊 **Structured Output**: Type-safe response parsing with JSON schemas
  - 🔍 **Observability**: Built-in tracing system (coming in Phase 2)
  - 🎭 **Agent System**: Event-driven agent coordination (coming in Phase 2)
  - 🏗️ **OTP Design**: Supervised processes for reliability

  ## Quick Start

  ### Simple Text Generation

      alias Mojentic.LLM.{Broker, Message}
      alias Mojentic.LLM.Gateways.Ollama

      broker = Broker.new("qwen3:32b", Ollama)
      messages = [Message.user("What is Elixir?")]
      {:ok, response} = Broker.generate(broker, messages)

  ### Structured Output

      schema = %{
        type: "object",
        properties: %{
          sentiment: %{type: "string"},
          confidence: %{type: "number"}
        }
      }

      {:ok, result} = Broker.generate_object(broker, messages, schema)

  ### Tool Usage

      defmodule MyTool do
        @behaviour Mojentic.LLM.Tools.Tool

        @impl true
        def run(args), do: {:ok, %{result: "tool result"}}

        @impl true
        def descriptor, do: %{...}
      end

      tools = [MyTool]
      {:ok, response} = Broker.generate(broker, messages, tools)

  ## Architecture

  ### Layer 1: LLM Integration (Stable)

  The foundational layer provides direct LLM interaction capabilities:

  - `Mojentic.LLM.Broker` - Main interface for LLM interactions
  - `Mojentic.LLM.Gateway` - Behaviour for LLM provider implementations
  - Gateway implementations: `Ollama`, `OpenAI` (planned), `Anthropic` (planned)
  - Message models and adapters
  - Tool system via behaviours
  - `Mojentic.Error` - Standardized error types and helpers

  ### Error Handling

  Mojentic follows Elixir conventions by returning `{:ok, result}` or `{:error, reason}` tuples.
  The `Mojentic.Error` module provides standardized error types:

      # Simple atom errors
      {:error, :invalid_response}
      {:error, :model_not_supported}
      {:error, :timeout}

      # Tagged tuple errors with context
      {:error, {:gateway_error, "Connection failed"}}
      {:error, {:http_error, 404}}
      {:error, {:tool_error, "Invalid parameters"}}

  Use helper functions for consistent error creation:

      alias Mojentic.Error
      Error.gateway_error("Connection failed")
      Error.http_error(404)

  ### Layer 2: Agent System (Coming Soon)

  Event-driven agent coordination system:

  - `Mojentic.Dispatcher` - Event routing and processing (GenServer)
  - `Mojentic.Router` - Event-to-agent routing configuration
  - `Mojentic.Agent` - Behaviour for all agents
  - Specialized agent implementations
  - Async event processing via OTP

  ## Configuration

  ### Environment Variables

  - `OLLAMA_HOST` - Ollama server URL (default: http://localhost:11434)

  ## Examples

  See the `examples/` directory for complete examples:

  - `simple_llm.exs` - Basic text generation
  - `structured_output.exs` - JSON schema-based responses
  - `tool_usage.exs` - LLM calling custom functions

  ## Installation

  Add `mojentic` to your list of dependencies in `mix.exs`:

      def deps do
        [
          {:mojentic, "~> 0.1.0"}
        ]
      end

  """

  @doc """
  Returns the version of Mojentic.
  """
  def version, do: "0.1.0"
end
