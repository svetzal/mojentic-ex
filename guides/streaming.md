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

## Single-turn streaming with terminal completion evidence

Use `Broker.generate_stream_events(broker, messages, config)` when incomplete
output must never authorize an action. It streams one turn and yields:

- `{:content, text}`: visible assistant content, in order.
- `{:completed, %{finish_reason: finish_reason, usage: usage, model: model}}`:
  terminal success. `usage` and `model` are `nil` when the provider does not
  report them.
- `{:error, reason}`: terminal failure.

Exactly one terminal event ends every stream. Nothing follows it.

```elixir
broker
|> Broker.generate_stream_events(messages)
|> Enum.reduce_while("", fn
  {:content, text}, acc -> {:cont, acc <> text}
  {:completed, _evidence}, acc -> {:halt, {:ok, acc}}
  {:error, reason}, _acc -> {:halt, {:error, reason}}
end)
```

The OpenAI and Ollama gateways support this API. Their completion rules:

| Outcome | OpenAI-compatible | Ollama |
| ------- | ----------------- | ------ |
| `{:completed, evidence}` | `finish_reason: "stop"` and `data: [DONE]` | final frame with `done: true` and `done_reason: "stop"` |
| `{:error, {:incomplete_completion, evidence}}` | `[DONE]` with any other finish reason | any other `done_reason` |
| `{:error, :incomplete_stream}` | end of stream without `[DONE]` | end of stream without a `done: true` frame |
| `{:error, {:provider_error, error}}` | an `error` event | an `error` frame |
| `{:error, :unexpected_tool_calls}` | a tool-call delta | a message with `tool_calls` |
| `{:error, :invalid_stream_event}` | a malformed event | a malformed frame |

`evidence` for an incomplete completion has the same shape as for completion:
finish reason, usage and provider model. Transport errors such as
`{:http_error, status}` and `:timeout` are also terminal errors.

Content yielded before an error is evidence, not a result. A failed turn stays
failed even if the partial content is valid JSON.

This API supplies no executable tools, forces zero tool iterations, and performs
no retry or recursion. It makes one HTTP request. Halting enumeration, or
stopping the consuming process, cancels that request. A gateway that does not
implement `complete_stream_events/3` yields
`{:error, :stream_events_unsupported}` before it sends any request.

The broker records the call in the tracer when the request starts. It records
the response, with the content received so far and the terminal evidence, when
the stream reaches its terminal event. See the broker guide for the trace
fields.

The Req transport disables redirects and retries, and applies its configured
timeout as an absolute streaming deadline. Applications must also bound the
entire call, including connection initialization; a streaming provider can emit
reasoning for a long time before it emits answer content.

Existing `generate_stream` remains a string-stream API for interactive
consumers. It does not provide this terminal proof.

## Structured output in streaming requests

`CompletionConfig.response_format` carries an optional response format. Every
gateway forwards it the same way in streaming and non-streaming requests:

| `response_format` | OpenAI-compatible body | Ollama body |
| ----------------- | ---------------------- | ----------- |
| `nil` | no `response_format` | no `format` |
| `%{type: :text}` | `response_format: %{type: "text"}` | no `format` |
| `%{type: :json_object}` | `response_format: %{type: "json_object"}` | `format: "json"` |
| `%{type: :json_object, schema: schema}` | `response_format: %{type: "json_schema", json_schema: %{name: "response", schema: schema}}` | `format: schema` |

```elixir
config = CompletionConfig.new(response_format: %{type: :json_object, schema: schema})
Broker.generate_stream_events(broker, messages, config)
```

This records what was requested. It is not proof that the provider enforced
the format. Validate the returned content yourself.
