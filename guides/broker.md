# LLM Broker Guide

The `Mojentic.LLM.Broker` is the central interface for interacting with Large Language Models in Mojentic. It provides a consistent API across different LLM providers (gateways) and handles tool execution, error handling, and message management.

## Overview

The Broker acts as an intermediary between your application and LLM providers:

```
Your App → Broker → Gateway → LLM Provider
                ↓
            Tool Execution
```

## Creating a Broker

```elixir
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Gateways.Ollama

# Basic broker
broker = Broker.new("llama3.2", Ollama)

# With correlation ID for request tracking
broker = Broker.new("llama3.2", Ollama, "request-abc-123")
```

### Broker Structure

```elixir
%Broker{
  model: "llama3.2",           # Model identifier
  gateway: Ollama,             # Gateway module
  correlation_id: "request-123" # Optional tracking ID
}
```

## Text Generation

The primary use case is generating text responses:

```elixir
messages = [Message.user("Explain Elixir in one sentence")]

case Broker.generate(broker, messages) do
  {:ok, response} ->
    IO.puts(response)
    # "Elixir is a functional, concurrent programming language..."
    
  {:error, reason} ->
    Logger.error("Generation failed: #{inspect(reason)}")
end
```

### With Configuration

```elixir
config = CompletionConfig.new(
  temperature: 0.3,  # Lower = more focused
  max_tokens: 500
)

{:ok, response} = Broker.generate(broker, messages, [], config)
```

### With Tools

```elixir
tools = [DateResolver, CurrentDateTime]
{:ok, response} = Broker.generate(broker, messages, tools, config)
```

## Structured Output

Generate responses conforming to a JSON schema:

```elixir
schema = %{
  type: "object",
  properties: %{
    title: %{type: "string"},
    summary: %{type: "string"},
    keywords: %{
      type: "array",
      items: %{type: "string"}
    }
  },
  required: ["title", "summary"]
}

messages = [Message.user("Analyze: Elixir is a functional language")]

case Broker.generate_object(broker, messages, schema) do
  {:ok, analysis} ->
    IO.inspect(analysis)
    # %{
    #   "title" => "Elixir Language Analysis",
    #   "summary" => "Functional programming language...",
    #   "keywords" => ["functional", "concurrent", "BEAM"]
    # }
    
  {:error, :invalid_response} ->
    Logger.error("LLM didn't return valid JSON")
end
```

## Tool Execution Flow

When tools are provided, the Broker handles a recursive loop:

1. Send messages to LLM
2. If LLM requests tools:
   - Execute each tool
   - Add tool results to conversation
   - Return to step 1
3. Return final text response

```elixir
# Example: Date resolution tool usage
messages = [Message.user("What's the date next Monday?")]
tools = [DateResolver]

# The broker will:
# 1. Call LLM with the question
# 2. LLM responds with tool call request
# 3. Broker executes DateResolver.run(args)
# 4. Broker adds result to conversation
# 5. Calls LLM again with tool result
# 6. LLM responds with final answer
{:ok, response} = Broker.generate(broker, messages, tools)
```

### Tool Call Handling

The broker automatically:

- Matches tool calls to available tools
- Executes tools with provided arguments
- Handles tool errors gracefully
- Logs tool execution (info, warnings, errors)

```elixir
# Tool not found
23:10:42.490 [warning] Tool not found: unknown_tool
23:10:42.490 [error] Tool execution failed: Tool error: Tool not found: unknown_tool

# Successful tool execution
23:10:42.491 [info] Processing 1 tool call(s)
23:10:42.491 [info] Executing tool: resolve_date
```

## Message Management

The Broker accepts a list of messages representing the conversation:

```elixir
messages = [
  Message.system("You are a helpful coding assistant"),
  Message.user("How do I read a file in Elixir?"),
  Message.assistant("You can use File.read/1..."),
  Message.user("What about streaming?")
]

{:ok, response} = Broker.generate(broker, messages)
```

### Message Types

- `system/1` - Set LLM behavior and context
- `user/1` - User input
- `assistant/1` - LLM responses (for history)
- `tool_call/2` - LLM requesting tool execution
- `tool_result/3` - Tool execution results

## Error Handling

The Broker returns standardized error tuples:

```elixir
case Broker.generate(broker, messages) do
  {:ok, response} ->
    # Success
    
  {:error, :timeout} ->
    # Request timed out
    
  {:error, :invalid_response} ->
    # LLM returned invalid format
    
  {:error, {:http_error, 429}} ->
    # Rate limited
    
  {:error, {:http_error, 500}} ->
    # Server error
    
  {:error, {:gateway_error, message}} ->
    # Gateway-specific error
    
  {:error, {:tool_error, message}} ->
    # Tool execution failed
end
```

### Error Recovery

```elixir
def generate_with_retry(broker, messages, max_retries \\ 3) do
  case Broker.generate(broker, messages) do
    {:ok, response} ->
      {:ok, response}
      
    {:error, :timeout} when max_retries > 0 ->
      Logger.warn("Timeout, retrying...")
      Process.sleep(1000)
      generate_with_retry(broker, messages, max_retries - 1)
      
    error ->
      error
  end
end
```

## Correlation IDs

Track requests across your system:

```elixir
# Generate unique ID
correlation_id = UUID.uuid4()
broker = Broker.new("llama3.2", Ollama, correlation_id)

# ID flows through all operations
{:ok, response} = Broker.generate(broker, messages)

# Later, find logs/events by correlation_id
# [info] [request-abc-123] Processing tool call
# [info] [request-abc-123] Executing tool: resolve_date
```

## Configuration Options

Fine-tune LLM behavior:

```elixir
alias Mojentic.LLM.CompletionConfig

# Creative writing
config = CompletionConfig.new(temperature: 1.5, max_tokens: 2000)

# Factual responses
config = CompletionConfig.new(temperature: 0.1, max_tokens: 500)

# Long context
config = CompletionConfig.new(num_ctx: 32768)

# Constrained generation
config = CompletionConfig.new(
  temperature: 0.7,
  num_predict: 256  # Limit response length
)
```

## Best Practices

### 1. Use System Messages

Set clear instructions:

```elixir
messages = [
  Message.system("""
  You are a helpful assistant that provides concise answers.
  Always format code examples with proper syntax highlighting.
  """),
  Message.user("How do I create a GenServer?")
]
```

### 2. Handle Tool Errors

Tools can fail:

```elixir
defmodule MyTool do
  @behaviour Mojentic.LLM.Tools.Tool
  
  def run(args) do
    with {:ok, value} <- validate_args(args),
         {:ok, result} <- process(value) do
      {:ok, result}
    else
      {:error, reason} -> {:error, {:tool_error, reason}}
    end
  end
end
```

### 3. Manage Context Windows

Long conversations need truncation:

```elixir
def keep_recent_messages(messages, max_count \\ 10) do
  messages
  |> Enum.take(-max_count)
end

messages = keep_recent_messages(conversation_history)
{:ok, response} = Broker.generate(broker, messages)
```

### 4. Use Appropriate Timeouts

Configure gateway timeouts for large models:

```elixir
# In config.exs or environment
System.put_env("OLLAMA_TIMEOUT", "600000")  # 10 minutes
```

## Advanced Usage

### Multiple Models

```elixir
# Use different models for different tasks
fast_broker = Broker.new("llama3.2:1b", Ollama)
smart_broker = Broker.new("llama3.2:70b", Ollama)

# Quick classification
{:ok, category} = Broker.generate(fast_broker, classify_messages)

# Deep analysis
{:ok, analysis} = Broker.generate(smart_broker, analysis_messages)
```

### Tool Composition

```elixir
# Combine multiple tools
tools = [
  DateResolver,
  CurrentDateTime,
  WeatherTool,
  CalculatorTool
]

# LLM can use any tool as needed
{:ok, response} = Broker.generate(broker, messages, tools)
```

### Schema Validation

```elixir
# Strict schemas ensure valid output
schema = %{
  type: "object",
  properties: %{
    confidence: %{type: "number", minimum: 0, maximum: 1},
    category: %{type: "string", enum: ["tech", "business", "other"]}
  },
  required: ["confidence", "category"],
  additionalProperties: false
}

case Broker.generate_object(broker, messages, schema) do
  {:ok, result} ->
    # Guaranteed to have required fields
    if result["confidence"] > 0.8 do
      process_high_confidence(result)
    end
end
```

## See Also

- [Getting Started](getting_started.html)
- [Tool Usage](tool_usage.html)
- [Structured Output](structured_output.html)
- [Gateway API](Mojentic.LLM.Gateway.html)
