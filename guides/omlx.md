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

- `temperature` and `max_tokens`. The gateway always sends `max_tokens`, never
  `max_completion_tokens`.
- `top_p`, `top_k` and `reasoning_effort`, when they are set.
- `response_format`, in the OpenAI-compatible shape.
- The tools that you give to the broker.

The gateway does not send `num_ctx` or `num_predict`. oMLX sets the context
length for each model.

## Thinking

The model's reasoning (`reasoning_content`) is in `GatewayResponse.thinking`.
Use `Broker.generate_response/4` to get the full gateway response.

`reasoning_effort` goes to the model's chat template. Its effect depends on
the model. When `reasoning_effort` is `nil`, the model's default applies.
Qwen 3 models think by default.

The streaming APIs do not yield reasoning. `Broker.generate_stream_events/3`
has no thinking event, and the legacy `Broker.generate_stream/4` has no
thinking chunk.

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
