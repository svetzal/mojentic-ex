# Streaming Responses

Streaming allows you to receive LLM responses chunk-by-chunk as they are
generated, improving perceived latency for users.

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

Mojentic supports streaming even when tools are involved. The broker will pause
streaming to execute tools and then resume streaming the final response.

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

For integration with Phoenix LiveView or other async processes, you can consume
the stream asynchronously. The stream implements the `Enumerable` protocol, so
it works with standard Elixir stream functions.

## Single-turn completion evidence

Use `Broker.generate_stream_events(broker, messages, config)` when incomplete
output must never authorize an action. This additive Elixir API yields content
as `{:content, text}` and requires a terminal `{:completed, metadata}` event.
The OpenAI gateway requires both `finish_reason: "stop"` and `[DONE]`. Metadata
includes the provider model and token usage when supplied. An error or EOF
without completion is a failed turn, even if the partial content is valid JSON.

This API supplies no executable tools, forces zero tool iterations, and performs
no retry. Native tool requests are rejected. Existing `generate_stream` remains
a string-stream API for interactive consumers; it does not provide this terminal
proof. Gateways that do not implement event streaming fail before dispatch.

Keep received content as evidence on failure, and halt enumeration to cancel the
request. The Req transport uses one HTTP request, disables redirects and
retries,
and applies its configured timeout as an absolute streaming deadline.
Applications
must also bound the entire call, including connection initialization; a
streaming
provider can emit reasoning for a long time before it emits answer content.

This event API is currently an Elixir-specific safety extension; the other ports
retain their existing streaming interfaces. It does not change their parity
claims.
