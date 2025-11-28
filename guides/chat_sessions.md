# Chat Sessions

`Mojentic.LLM.ChatSession` manages the state of a conversation, handling message history, context window limits, and system prompts.

## Creating a Session

```elixir
alias Mojentic.LLM.{ChatSession, Broker}
alias Mojentic.LLM.Gateways.Ollama

# Initialize broker
broker = Broker.new("qwen3:32b", Ollama)

# Start a session
{:ok, session} = ChatSession.start_link(broker, system_prompt: "You are a helpful assistant.")
```

## Interacting

```elixir
# Send a message
{:ok, response} = ChatSession.send_message(session, "Hello!")
IO.puts(response)

# Send another message (history is preserved)
{:ok, response} = ChatSession.send_message(session, "What was my last message?")
IO.puts(response)
```

## Context Management

The ChatSession automatically manages the context window. When the history exceeds the model's token limit, older messages are summarized or truncated based on the configured strategy.

## Using Tools

You can register tools with a chat session, making them available for all interactions:

```elixir
alias Mojentic.LLM.Tools.DateResolver

{:ok, session} = ChatSession.start_link(broker, tools: [DateResolver])
```
