# Introduction to Mojentic for Elixir

Mojentic is a comprehensive LLM integration framework designed to make building AI-powered applications simple, reliable, and maintainable. The Elixir implementation embraces functional programming principles and the actor model through OTP.

## Philosophy

The Elixir port of Mojentic follows a "thinking in data" philosophy:

- **Data flows through transformations**: Functions transform data through pipelines
- **Pattern matching as validation**: Data shapes determine program flow
- **Let it crash**: Use supervision trees and recovery strategies
- **Processes for concurrency**: Leverage OTP for concurrent operations
- **Explicit over implicit**: Clear function signatures and return types

## Core Features

### Layer 1: LLM Integration

- **LLM Broker**: Central interface for LLM interactions with any provider
- **Multiple Gateways**: Support for Ollama, OpenAI, and Anthropic (planned)
- **Tool Calling**: Recursive tool execution with automatic retries
- **Structured Output**: Schema-based JSON parsing and validation
- **Message History**: Conversation context management
- **Streaming**: Real-time response streaming (planned)

### Error Handling

Mojentic uses idiomatic Elixir error handling:

```elixir
case Broker.generate(broker, messages) do
  {:ok, response} ->
    IO.puts("Success: #{response}")

  {:error, reason} ->
    Logger.error("Failed: #{inspect(reason)}")
end
```

All errors follow the `{:ok, result} | {:error, reason}` pattern, with standardized error types in the `Mojentic.Error` module.

## Quick Example

```elixir
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

# Create a broker
broker = Broker.new("llama3.2", Ollama)

# Generate text
messages = [Message.user("What is Elixir?")]
{:ok, response} = Broker.generate(broker, messages)
IO.puts(response)
```

## Architecture

Mojentic is organized into layers:

1. **Layer 1**: Core LLM integration (Broker, Gateways, Tools, Messages)
2. **Layer 2**: Tracer system for observability (planned)
3. **Layer 3**: Agent system for complex workflows (planned)

## Next Steps

- [Getting Started](getting_started.html) - Installation and basic usage
- [Broker Guide](broker.html) - Understanding the LLM Broker
- [Tool Usage](tool_usage.html) - Building and using tools
- [Structured Output](structured_output.html) - Working with schemas
