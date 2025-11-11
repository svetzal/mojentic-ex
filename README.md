# Mojentic

An LLM integration framework for Elixir.

Mojentic provides a clean abstraction over multiple LLM providers (OpenAI, Ollama, Anthropic) with tool support, structured output generation, and an event-driven agent system.

## Features

- 🔌 **Multiple Providers**: OpenAI, Ollama, Anthropic (Ollama implemented in Phase 1)
- 🛠️ **Tool Support**: Allow LLMs to call functions
- 📊 **Structured Output**: Type-safe response parsing with JSON schemas
- 🔍 **Observability**: Built-in tracing system (coming in Phase 2)
- 🎭 **Agent System**: Event-driven agent coordination (coming in Phase 2)
- 🏗️ **OTP Design**: Supervised processes for reliability

## Installation

Add `mojentic` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mojentic, "~> 0.1.0"}
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

### Layer 1: LLM Integration (Stable)

The foundational layer provides direct LLM interaction capabilities:

- `Mojentic.LLM.Broker` - Main interface for LLM interactions
- `Mojentic.LLM.Gateway` - Behaviour for LLM provider implementations
- Gateway implementations: `Ollama`, `OpenAI` (planned), `Anthropic` (planned)
- Message models and adapters
- Tool system via behaviours

### Layer 2: Agent System (Coming Soon)

Event-driven agent coordination system:

- `Mojentic.Dispatcher` - Event routing and processing (GenServer)
- `Mojentic.Router` - Event-to-agent routing configuration
- `Mojentic.Agent` - Behaviour for all agents
- Specialized agent implementations
- Async event processing via OTP

## Documentation

For detailed documentation, run:

```bash
mix docs
```

Then open `doc/index.html` in your browser.

## Development

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests (when available)
mix test

# Format code
mix format

# Run code quality checks
mix credo
```

## Implementation Status

### Phase 1: Core Infrastructure ✅

- [x] Project setup with Mix
- [x] Core type modules (Message, ToolCall, GatewayResponse, CompletionConfig)
- [x] Gateway behaviour
- [x] Tool behaviour
- [x] Ollama gateway implementation
- [x] LLM Broker with automatic tool calling
- [x] DateResolver example tool
- [x] Three example scripts (simple_llm, structured_output, tool_usage)

### Phase 2: Advanced Features (Planned)

- [ ] ChatSession GenServer for conversation management
- [ ] Tracer system for observability
- [ ] OpenAI gateway
- [ ] Anthropic gateway

### Phase 3: Agent System (Planned)

- [ ] Event system with Dispatcher GenServer
- [ ] Router for event-to-agent routing
- [ ] Agent behaviour and implementations
- [ ] Supervision trees

## License

MIT License - see LICENSE.md

## Credits

Mojentic is a Mojility product by Stacey Vetzal.

Accent Green: #6bb660
Dark Grey: #666767

