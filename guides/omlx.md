# oMLX Gateway

[oMLX](https://github.com/jundot/omlx) is an LLM server for Apple Silicon.
`Mojentic.LLM.Gateways.OMLX` connects the broker to it.

oMLX uses the OpenAI chat completions protocol, but do not use the OpenAI
gateway for it. The OpenAI gateway changes requests for model names that it
does not know, drops the model's reasoning, and reads the OpenAI environment
variables. The oMLX gateway sends each configured parameter unchanged, for
every model name.

## Configuration

The gateway reads three environment variables.

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `OMLX_HOST` | `http://localhost:8000` | Server address, without `/v1`. The gateway adds `/v1` to each path. |
| `OMLX_API_KEY` | none | Sent as `Authorization: Bearer <key>`. When it is not set, requests have no authorization header. |
| `OMLX_TIMEOUT` | `600000` | Timeout in milliseconds for every request, including model load. |

```bash
export OMLX_HOST=http://localhost:8000
export OMLX_API_KEY=your-omlx-key   # only when the server requires a key
```

```elixir
alias Mojentic.LLM.{Broker, Message}
alias Mojentic.LLM.Gateways.OMLX

broker = Broker.new("Qwen3.8-27B-MLX-8bit", OMLX)
{:ok, text} = Broker.generate(broker, [Message.user("Hello!")])
```

## Request parameters

A chat request sends these `CompletionConfig` fields:

- `temperature` and `max_tokens`, only when set. The output-limit name is
  `max_tokens`, never `max_completion_tokens`. Unset limits use server settings.
- `top_p`, `top_k` and `reasoning_effort`, when they are set.
- `response_format`, in the OpenAI-compatible shape.
- The tools that you give to the broker.

The gateway does not send `num_ctx` or `num_predict`. oMLX sets the context
length for each model.

## Thinking

The model's reasoning (`reasoning_content`) is in `GatewayResponse.thinking`.
Use `Broker.generate_response/4` to get the full gateway response.

`:disabled` and `:enabled` send `enable_thinking: false/true`. Named levels
`:low`, `:medium`, `:high` and `:xhigh` send exact `reasoning_effort` strings.
Omitted effort is unknown. Select `ReasoningProfile.qwen3_8()` explicitly to
validate disabled/low/medium/xhigh and native history before HTTP; model names
do not select a profile.

`Broker.generate_stream_events/3` has no thinking event. The legacy
`Broker.generate_stream/4` yields separate `{:thinking, text}` tuples.
`preserve_reasoning: true` retains native reasoning in completed Broker tool
continuations and requests `chat_template_kwargs.preserve_thinking: true`.
Retention defaults to off, does not enable reasoning and excludes failed or
cancelled streams. Server settings may override the preserve request.
`Message.reasoning_content` serializes natively without modifying OpenAI history.

## Truncation

When `max_tokens` stops generation during thinking, a non-streaming response
has the partial reasoning in `content`, `thinking` is `nil`, and
`finish_reason` is `"length"`. The gateway does not move text between the two
fields. When `finish_reason` is not `"stop"`, `content` is not an answer.
`Broker.generate/4` returns `{:error, {:incomplete_completion, "length"}}` for
this response.

## Structured output

`Broker.generate_object/4` sends
`response_format: {type: "json_schema", json_schema: {name: "response", schema: ...}}`.

When oMLX cannot compile a grammar for the schema, it does not enforce the
schema. It puts instructions in the prompt, and it sends a `Warning` response
header. On a request that asked for JSON (`generate_object/4`, or a
`response_format` of type `:json_object`), the gateway:

- puts the header value in `GatewayResponse.metadata`, with the key
  `"response_format_warning"`
- logs a warning

The gateway does not retry and does not fail. The warning is evidence. Always
validate the content against your schema.

## Streaming

Every oMLX chat stream starts with a keep-alive frame whose `model` is
`"keepalive"`, and oMLX sends more of them during a long prefill. The gateway
drops these frames before it parses the stream. So a stream that fails during
prefill does not report `"keepalive"` as the provider model.

`Broker.generate_stream_events/3` works with oMLX. It uses the OpenAI
completion rules: success needs a `finish_reason` of `"stop"` and the
`data: [DONE]` marker. See the [Streaming](streaming.md) guide.

## Models

```elixir
{:ok, models} = OMLX.get_available_models()   # sorted model ids
:ok = OMLX.load_model("Qwen3.8-27B-MLX-8bit")
:ok = OMLX.unload_model("Qwen3.8-27B-MLX-8bit")
```

- `load_model/1` blocks until the model is in memory, within
  `OMLX_TIMEOUT`. A chat request loads its model
  automatically, so use `load_model/1` only to warm up a model before its first
  request.
- `unload_model/1` on a model that is not loaded returns
  `{:error, {:http_error, 400, body}}`.
- oMLX downloads models only through its admin dashboard. The gateway has no
  pull operation.

## Embeddings

```elixir
{:ok, vector} = OMLX.calculate_embeddings("some text", "your-embedding-model")
```

You must give a model, because oMLX has no standard embedding model. A `nil`
model raises `ArgumentError` before the gateway sends a request. The gateway sends the text in
one request, with no chunking. A chat model returns
`{:error, {:http_error, 400, body}}`.

## Errors

oMLX errors use the OpenAI error shape. The gateway returns them unchanged:

- A non-2xx response is `{:error, {:http_error, status, body}}`, where `body`
  is the response body. A 401 is a missing or wrong API key. A 404 is an
  unknown model, and its message lists the available models.
- A connection failure is `{:error, {:request_failed, reason}}`.
- In `Broker.generate_stream_events/3`, a non-2xx response is
  `{:error, {:provider_error, %{status: status}}}`.

## Streaming timeout

`OMLX_TIMEOUT` bounds connection setup and idle waits between received stream
chunks. An active stream can run longer than that interval. Both streaming APIs
cancel the HTTP request when the consumer stops. Non-streaming requests,
including model loading, retain their configured request timeout.

Embedding requests require a nonblank model name. Empty or whitespace-only
names raise `ArgumentError` before any request.

Opt-in recovery freezes the complete encoded request once per logical completion.
The deterministic `ImmutableRequestWireTest` compares oMLX ordinary, structured,
legacy streaming and terminal-event requests with independently specified full
payloads and recovery-disabled bytes. It includes multimodal input, all supported
controls, prior tool IDs, arguments and results, and a completed-tool follow-up
that retries without executing the tool again. Mutable image-file changes during
admission cannot change that follow-up's encoded body. Native reasoning history
is not representable by the current `Message` struct; `reasoning_effort` and
received `thinking` keep their existing behavior.


## oMLX keepalives during recovery

With recovery enabled, both oMLX stream APIs ignore complete SSE data frames whose
`model` equals `keepalive`, including frames split across received chunks or
coalesced with real frames. Their received bytes count as raw progress only:
they produce no content, reasoning, tools, frame indexes or provider metadata.
Completion evidence retains the real provider's model and usage.

A keepalive-only truncated stream is not successful completion. The existing
attempt limit and admission policy still apply: ambiguous local oMLX failures
require explicit admission; a missing or undecided hook cannot authorize replay.
Once real content, reasoning or a tool fragment is observed, interruption ends
the logical request without a resend. A failed ChatSession stream cannot finalize
as a completed assistant response. Recovery-disabled streaming retains its
existing behavior.

The local `omlx-keepalive-v1` executable set runs with
`scripts/verify-omlx-keepalive-contract`, using the scripted loopback HTTP server
and production Req through gateways, Broker and ChatSession. See
`CONFORMANCE-3.0.0.md` for identities, named tests and the outstanding paired
provider-verification gap.
