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

### Cancellation migration and limits

Cancellation errors now retain the received HTTP status, headers and exact bytes,
including ordinary/structured partial bodies and stream fragments observed before
a blocked capture hook. Use `CompletionError.received_evidence(error)` only in an
explicit sensitive inspection/storage path; it returns `%{status: status,
headers: headers, body: body, ids: ids}` or `nil` when no response was observed.
`CompletionError.cause(error)` retains an available native transport or parser
cause separately. Safe history and lifecycle metadata retain the exact IDs and
received/delivered progress, with no raw response payload or credential headers.

The original observed transport cause also survives cancellation after the HTTP
worker has returned its normalized failure, before the recovery owner accepts it.
For example, a truncated response can return a `Req.TransportError` from ordinary
POST while `CompletionError.cause(error)` still exposes the observed
`Mint.TransportError`. Received evidence takes precedence over that normalized
result; when no received cause exists, the returned failure remains the fallback.
This applies to ordinary and structured completions as well as streams, including
broker/session forwarding. No extra request is made to recover the cause.

Cancellation before consumer acceptance of a terminal result produces the actual
attempt failure followed by exactly one terminal cancellation event. A terminal
frame alone does not authorize success: final capture/cleanup and consumer demand
must complete first. After terminal acceptance, completion is committed; a later
cancellation does not retract that result. Tools buffered by the broker are never
executed on a cancelled attempt, and cancelled session streams fail finalization.

If an enumerator is paused inside its own callback, it cannot forward mailbox
messages until it resumes. To cancel promptly while paused, retain the recovery
owner PID from `self()` inside the `:attempt_started` lifecycle observer and send
`{:cancel, cancel_ref}` directly to that PID. Capture hooks run in another request
worker and may be killed without a terminal trace notification. Evidence covers
bytes already exposed by ReqClient, not unread socket data. No additional read,
request, remote termination claim or active-generation deadline is introduced.
Custom HTTP implementations must honor the internal received-observer option to
provide this retention guarantee. Retries-disabled calls keep their existing path.

`Broker.generate_stream/4` remains a tool-executing stream. With recovery enabled,
it yields `{:error, error}` to the consumer instead of silently halting on adapter
failures, and may yield `{:thinking, text}` alongside strings. Tools execute only
after a successful tool completion; a failed follow-up request does not replay
tools. Handle these tuples before passing content to `IO.write/1`.

Recovery-enabled broker streaming suppresses default payload tracing, including
messages, accumulated content and tool arguments. The recovery `observer` supplies
safe lifecycle metadata. Error inspection and JSON encoding exclude response text
and original causes; `CompletionError.cause(error)` is the explicit private
inspection API and must not be sent to default logs. Raw per-wire capture is
available through the explicit `trace_observer` option described below. Cancellation
response evidence is also available through `CompletionError.received_evidence/1`. Providers expose no supported status, idempotency or
remote cancellation guarantee; see `Recovery.capabilities/1`.

The deterministic production-HTTP cases and gate results are recorded in
[RECOVERY-CONFORMANCE.md](https://github.com/svetzal/mojentic-ex/blob/main/RECOVERY-CONFORMANCE.md).


## Opt-in exact HTTP evidence

Add the callback inside the existing recovery configuration; ordinary and
structured completions and both public streaming APIs use the same contract:

```elixir
config = CompletionConfig.new(
  recovery: [
    max_attempts: 2,
    trace_observer: fn event ->
      # Persist in caller-owned storage with the desired security/retention policy.
      :ok = MyTraceStore.append(event.ids.logical_request_id, event)
      :ok
    end
  ]
)
```

Use `config` with a gateway or broker. Sessions accept
`recovery: config.recovery` on `ChatSession.send/3` and `send_stream/3`.
The safe lifecycle `observer` remains a separate callback. Enabling recovery alone
never enables raw capture, and the broker's ordinary tracer remains payload-free.

In dispatch order, the raw callback receives `:request` with the binary encoded
body, method, URL and supplied headers; `:response_headers` with status and headers;
`:response_data` for each exact observed binary chunk; and `:response_end` with
outcome and evidence availability. Each event carries the same unmasked logical
request ID, attempt ID and wire number as lifecycle/error metadata. HTTP failures,
malformed provider JSON and partial transport responses retain their observed
bytes. The callback receives credentials and payloads without masking; the library
does not persist them. With `cancel_ref`, the library retains received response
evidence in memory until the cancellation error is released. Default error
inspection, JSON, lifecycle events and logs omit it.

Return exactly `:ok`. An exception, throw, exit or any other return causes terminal
`capture_failed`, never another inference or successful session finalization.
Already delivered content remains delivered. Capture failure can prevent an end
notification; store the prefix as incomplete. Cancellation remains authoritative,
including while a callback is blocked, and cancellation before dispatch counts zero
attempts and produces no trace. Callbacks run in the request worker when cancellation
is configured, so storage must not depend on running in the completion caller.

The capture boundary is the default ReqClient, not TLS packets or transfer framing.
Header metadata contains supplied request headers and observed response headers,
not every generated transport header. HTTP data chunks can be coalesced. Provider
terminal markers can stop capture before HTTP EOF (`outcome: :consumer_halted`).
`:complete` means HTTP EOF, not successful provider decoding; `:failed` means the
observed HTTP/transport failure. A headers-only response with no data is available
empty-body evidence; failure before headers is `evidence: :unavailable`. Request
notification happens at authorized dispatch before waiting for response headers;
cancellation after the server receives the request retains that independent request
evidence even when no response is available. Undispatched cancellation has zero
attempts and no trace. Killed capture
workers do not promise a final end callback. Missing bytes are never reconstructed
or obtained by issuing another request. There is no trace truncation or byte-size
limit; caller storage must handle the observed stream. Non-2xx bodies are buffered
for error metadata. Interrupted non-2xx reads retain the received status, headers
and raw-byte progress with tracing enabled or disabled. Retry policy uses that
HTTP status: a truncated 401 cannot become a retryable transport failure.
Custom HTTP clients must implement `wire_trace` themselves;
these tests establish the default Req boundary contract.
