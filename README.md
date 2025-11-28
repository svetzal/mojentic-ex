# Mojentic

[![Hex.pm](https://img.shields.io/hexpm/v/mojentic.svg)](https://hex.pm/packages/mojentic)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/Elixir-1.15%2B-purple)](https://elixir-lang.org/)

An LLM integration framework for Elixir with full feature parity across Python, Rust, and TypeScript implementations.

Mojentic provides a clean abstraction over multiple LLM providers (OpenAI, Ollama) with tool support, structured output generation, streaming, and a complete event-driven agent system.

## 🚀 Features

- **🔌 Multiple Providers**: OpenAI and Ollama gateways
- **🛠️ Tool Support**: Extensible tool system with automatic recursive execution
- **📊 Structured Output**: Type-safe response parsing with JSON schemas
- **🌊 Streaming**: Real-time streaming with full tool calling support
- **🔍 Tracer System**: Complete observability for debugging and monitoring
- **🤖 Agent System**: Event-driven multi-agent coordination with ReAct pattern
- **🏗️ OTP Design**: GenServer-based components ready for supervision trees
- **📦 24 Examples**: Comprehensive examples demonstrating all features

## 📦 Installation

Add `mojentic` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mojentic, "~> 1.0.0"}
  ]
end
```

## Quick Start

### Simple Text Generation

```elixir
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

broker = Broker.new("qwen3:32b", Ollama)
messages = [Message.user("What is Elixir?")]
{:ok, response} = Broker.generate(broker, messages)
IO.puts(response)
```

### Structured Output

```elixir
schema = %{
  type: "object",
  properties: %{
    sentiment: %{type: "string"},
    confidence: %{type: "number"}
  },
  required: ["sentiment", "confidence"]
}

messages = [Message.user("I love this product!")]
{:ok, result} = Broker.generate_object(broker, messages, schema)
IO.inspect(result)
# => %{"sentiment" => "positive", "confidence" => 0.95}
```

### Tool Usage

```elixir
defmodule WeatherTool do
  @behaviour Mojentic.LLM.Tools.Tool

  @impl true
  def run(args) do
    location = Map.get(args, "location", "unknown")
    {:ok, %{location: location, temperature: 22, condition: "sunny"}}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: %{
          type: "object",
          properties: %{
            location: %{type: "string", description: "City name"}
          },
          required: ["location"]
        }
      }
    }
  end
end

tools = [WeatherTool]
messages = [Message.user("What's the weather in SF?")]
{:ok, response} = Broker.generate(broker, messages, tools)
IO.puts(response)
```

## Examples

See the `examples/` directory for complete runnable examples:

```bash
# Simple LLM text generation
mix run examples/simple_llm.exs

# Structured output with JSON schema
mix run examples/structured_output.exs

# Tool usage with automatic tool calling
mix run examples/tool_usage.exs
```

## Configuration

### Environment Variables

- `OLLAMA_HOST` - Ollama server URL (default: `http://localhost:11434`)

## Architecture

Mojentic is structured in three layers:

### Layer 1: LLM Integration

- `Mojentic.LLM.Broker` - Main interface for LLM interactions
- `Mojentic.LLM.Gateway` - Behaviour for LLM provider implementations
- Gateway implementations: `Ollama`, `OpenAI`
- `Mojentic.LLM.ChatSession` - Conversational session management
- `Mojentic.LLM.TokenizerGateway` - Token counting
- `Mojentic.LLM.EmbeddingsGateway` - Vector embeddings
- Comprehensive tool system with 10+ built-in tools

### Layer 2: Tracer System

- `Mojentic.Tracer.System` - Event recording GenServer
- `Mojentic.Tracer.EventStore` - Event persistence and querying
- Correlation ID tracking across requests
- LLM call, response, and tool events

### Layer 3: Agent System

- `Mojentic.AsyncDispatcher` - Event routing GenServer
- `Mojentic.Router` - Event-to-agent routing
- `Mojentic.Agents.BaseLLMAgent` - Foundation for LLM agents
- `Mojentic.Agents.AsyncLLMAgent` - Async agent with GenServer
- `Mojentic.Agents.IterativeProblemSolver` - Multi-step reasoning
- `Mojentic.Agents.SimpleRecursiveAgent` - Self-recursive processing
- `Mojentic.Context.SharedWorkingMemory` - Agent context sharing
- ReAct pattern implementation

## 📚 Documentation

Generate documentation locally:

```bash
mix docs
open doc/index.html
```

## 🧪 Development

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test

# Format code
mix format

# Run code quality checks
mix credo --strict

# Security audit
mix deps.audit
```

## 📄 License

MIT License - see [LICENSE](LICENSE)

## Credits

Mojentic is a [Mojility](https://mojility.com) product by Stacey Vetzal.
