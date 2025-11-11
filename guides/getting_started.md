# Getting Started with Mojentic

This guide will help you get up and running with Mojentic in your Elixir project.

## Installation

Add Mojentic to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:mojentic, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Prerequisites

Mojentic requires:

- Elixir 1.15 or later
- A local or remote LLM service (Ollama, OpenAI, etc.)

### Setting up Ollama (Local LLMs)

1. Install Ollama from [ollama.ai](https://ollama.ai)
2. Pull a model:

```bash
ollama pull llama3.2
```

3. Start the Ollama service (runs on `http://localhost:11434` by default)

### Setting up OpenAI (Planned)

```elixir
# Set your API key
System.put_env("OPENAI_API_KEY", "your-api-key")
```

## Your First LLM Call

Create a simple script to test your setup:

```elixir
# In a script or IEx session
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

# Create a broker with your model
broker = Broker.new("llama3.2", Ollama)

# Create a message
messages = [Message.user("What is the capital of France?")]

# Generate a response
case Broker.generate(broker, messages) do
  {:ok, response} ->
    IO.puts("AI: #{response}")
    
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
```

## Understanding the Broker

The `Broker` is your main interface to LLMs. It handles:

- Model selection
- Gateway routing
- Message formatting
- Tool execution
- Error handling

### Basic Broker Usage

```elixir
# Simple text generation
broker = Broker.new("llama3.2", Ollama)
messages = [Message.user("Hello!")]
{:ok, response} = Broker.generate(broker, messages)

# With configuration
config = CompletionConfig.new(temperature: 0.7, max_tokens: 1000)
{:ok, response} = Broker.generate(broker, messages, [], config)

# With correlation ID for tracking
broker = Broker.new("llama3.2", Ollama, "request-123")
```

## Working with Messages

Messages form the conversation context:

```elixir
alias Mojentic.LLM.Message

# Different message types
messages = [
  Message.system("You are a helpful assistant"),
  Message.user("What's the weather?"),
  Message.assistant("I don't have access to weather data"),
  Message.user("Can you tell me a joke instead?")
]

{:ok, response} = Broker.generate(broker, messages)
```

## Structured Output

Parse responses into structured data:

```elixir
# Define a schema
schema = %{
  type: "object",
  properties: %{
    name: %{type: "string"},
    age: %{type: "integer"},
    hobbies: %{
      type: "array",
      items: %{type: "string"}
    }
  },
  required: ["name", "age"]
}

messages = [Message.user("Generate a person profile")]

case Broker.generate_object(broker, messages, schema) do
  {:ok, person} ->
    IO.inspect(person)
    # %{"name" => "Alice", "age" => 30, "hobbies" => ["reading", "coding"]}
    
  {:error, reason} ->
    IO.puts("Failed: #{inspect(reason)}")
end
```

## Using Tools

Tools let LLMs perform actions:

```elixir
alias Mojentic.LLM.Tools.DateResolver

messages = [
  Message.user("What date is next Friday?")
]

# Pass tools to the broker
tools = [DateResolver]
{:ok, response} = Broker.generate(broker, messages, tools)
```

## Configuration Options

Customize LLM behavior with `CompletionConfig`:

```elixir
alias Mojentic.LLM.CompletionConfig

config = CompletionConfig.new(
  temperature: 0.7,      # Randomness (0.0-2.0)
  max_tokens: 2000,      # Maximum response length
  num_ctx: 8192,         # Context window size
  num_predict: 1024      # Prediction length
)

{:ok, response} = Broker.generate(broker, messages, [], config)
```

## Error Handling

All Mojentic functions return `{:ok, result}` or `{:error, reason}`:

```elixir
case Broker.generate(broker, messages) do
  {:ok, response} ->
    # Handle success
    process_response(response)
    
  {:error, :timeout} ->
    # Handle timeout
    Logger.warn("Request timed out")
    
  {:error, {:http_error, status}} ->
    # Handle HTTP errors
    Logger.error("HTTP #{status}")
    
  {:error, {:gateway_error, msg}} ->
    # Handle gateway errors
    Logger.error("Gateway error: #{msg}")
    
  {:error, reason} ->
    # Handle other errors
    Logger.error("Error: #{inspect(reason)}")
end
```

## Next Steps

- [Broker Guide](broker.html) - Deep dive into the Broker
- [Tool Usage](tool_usage.html) - Building custom tools
- [Structured Output](structured_output.html) - Working with schemas
- [API Reference](api-reference.html) - Complete API documentation
