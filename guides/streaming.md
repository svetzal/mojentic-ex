# Streaming Responses

Streaming allows you to receive LLM responses chunk-by-chunk as they are generated, improving perceived latency for users.

## Basic Streaming

Use `Broker.generate_stream/3` to get a stream of chunks:

```elixir
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.Ollama

broker = Broker.new("qwen3:32b", Ollama)
messages = [Message.user("Tell me a story.")]

stream = Broker.generate_stream(broker, messages)

for {:ok, chunk} <- stream do
  IO.write(chunk)
end
```

## Streaming with Tools

Mojentic supports streaming even when tools are involved. The broker will pause streaming to execute tools and then resume streaming the final response.

```elixir
alias Mojentic.LLM.Tools.DateResolver

tools = [DateResolver]
stream = Broker.generate_stream(broker, messages, tools)

# The stream will contain text chunks.
# Tool execution happens transparently in the background.
for {:ok, chunk} <- stream do
  IO.write(chunk)
end
```

## Async Streams

For integration with Phoenix LiveView or other async processes, you can consume the stream asynchronously. The stream implements the `Enumerable` protocol, so it works with standard Elixir stream functions.
