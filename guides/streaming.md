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
- `{:completed, evidence}`: terminal success. `evidence` is
  `%{finish_reason: finish_reason, usage: usage, provider_model: provider_model, metadata: metadata}`.
  `usage`, `provider_model` and `metadata` are `nil` when the provider does not
  report them. For Ollama, `metadata` holds the final frame's
  `total_duration`, `load_duration`, `prompt_eval_duration` and `eval_duration`
  (nanoseconds). For OpenAI, `metadata` is `nil`.
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
| `{:error, {:incomplete_completion, evidence}}` | `[DONE]` with any other finish reason | any other `done_reason`, or none |
| `{:error, {:incomplete_stream, evidence}}` | end of stream without `[DONE]` | end of stream without a `done: true` frame |
| `{:error, {:provider_error, error}}` | an `error` event | an `error` frame |
| `{:error, {:provider_error, %{status: status}}}` | a non-2xx HTTP status | a non-2xx HTTP status |
| `{:error, {:request_failed, reason}}` | the connection or body read failed, including `:timeout` | the same |
| `{:error, :unexpected_tool_calls}` | a tool-call delta | a message with `tool_calls` |
| `{:error, :invalid_stream_event}` | a malformed event | a malformed frame |

`evidence` for an incomplete completion has the same shape as for completion:
finish reason, usage, provider model and provider metadata. For an incomplete
stream, `evidence` holds whatever arrived before the stream ended, in the same
shape, or is `nil` when nothing arrived. An OpenAI stream can have reported the
model, a finish reason and usage; an Ollama stream retains any reported usage and timing fields, even when
those fields arrive before its final frame.

Ollama servers too old to send `done_reason` cannot use this API: their final
frame is an incomplete completion with a `nil` finish reason.

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

Stopping early is not an error. If the consumer halts before the terminal
event, the broker cancels the request and records the call but no response.

The Req transport disables redirects and retries. OpenAI and Ollama apply
the configured timeout as an absolute streaming deadline; oMLX applies it to
connection setup and idle waits between chunks. Applications must also bound the
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

## Opt-in completion recovery

The behavior above describes `recovery: nil`. OpenAI, Ollama and oMLX support
request-level recovery through both streaming entrypoints:

```elixir
config = CompletionConfig.new(
  recovery: [max_attempts: 3, base_delay: 100, delay_ceiling: 30_000]
)

Broker.generate_stream_events(broker, messages, config)
|> Enum.reduce_while("", fn
  {:content, text}, partial -> {:cont, partial <> text}
  {:completed, evidence}, text -> {:halt, {:ok, text, evidence}}
  {:error, error}, _partial -> {:halt, {:error, error}}
end)
```

Recovery errors are `Mojentic.LLM.CompletionError` structs, with bounded history,
logical and wire-attempt identities, original status and Retry-After evidence.
`progress.observed` and `progress.delivered` separately track content, reasoning,
tool fragments and completed tool calls; `raw_bytes` counts keepalives too.
After semantic output is observed, a failure has `reason: :stream_interrupted`:
no replay, subsequent request or successful terminal is emitted. Terminal-event
APIs still supply no tools and suppress reasoning. Suppressed reasoning and
buffered tool fragments therefore count as observed but not delivered. The
legacy adapter API delivers completed calls, and opt-in reasoning as
`{:thinking, text}`; incomplete calls are never emitted for execution.

OpenAI permits eligible pre-output recovery under its remote-provider policy.
Ollama and oMLX require explicit admission when prior acceptance is unknown.
An asynchronous `admission` callback returns `:allow`, `:reject` or `:pending`;
resolve pending decisions with
`send(context.reply_to, {:recovery_admission, context.ref, :allow})` only after
the application has established that resending is acceptable. Local socket
closure is not evidence that remote inference stopped. Admission is not a wire
attempt, and a recovery retry never replenishes broker tool depth.

Send `{:cancel, cancel_ref}` to the process enumerating the stream after supplying
that reference in recovery options. Cancellation works during the active request,
admission and backoff. Consumer halt and consumer process termination close the
locally owned request and recovery work. The production transport applies timeouts
to connection setup and idle waits, without a total generation timeout. A recovery
budget starts after the first failure; it does not truncate active generation.
Retry-After cannot bypass the delay ceiling or recovery deadline.

`Broker.generate_stream/4` remains a tool-executing stream. With recovery enabled,
it yields `{:error, error}` to the consumer instead of silently halting on adapter
failures, and may yield `{:thinking, text}` alongside strings. Tools execute only
after a successful tool completion; a failed follow-up request does not replay
tools. Handle these tuples before passing content to `IO.write/1`.

Recovery-enabled broker streaming suppresses default payload tracing, including
messages, accumulated content and tool arguments. The recovery `observer` supplies
safe lifecycle metadata. Error inspection and JSON encoding exclude response text
and original causes; `CompletionError.cause(error)` is the explicit private
inspection API and must not be sent to default logs. Exact raw wire trace hooks
remain a separate increment. Providers expose no supported status, idempotency or
remote cancellation guarantee; see `Recovery.capabilities/1`.

The deterministic production-HTTP cases and gate results are recorded in
[RECOVERY-CONFORMANCE.md](https://github.com/svetzal/mojentic-ex/blob/main/RECOVERY-CONFORMANCE.md).
