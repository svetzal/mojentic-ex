# Completion recovery conformance: Elixir single-attempt increment

This implementation covers opt-in ordinary and structured completion failures.
It does not implement resends or claim full transient recovery parity. No live
models, sibling ports, harness experiments, or benchmarks were used.

## Migration

Legacy calls retain their success values and legacy error forms. Their existing
Req retry defaults remain unchanged. Opt in with `CompletionConfig.recovery`:

```elixir
alias Mojentic.LLM.{Broker, CompletionConfig, CompletionError, Message}
alias Mojentic.LLM.Gateways.Ollama

config = CompletionConfig.new(recovery: [max_attempts: 1, observer: &IO.inspect/1])
broker = Broker.new("local-model", Ollama)

case Broker.generate(broker, [Message.user("Hello")], nil, config) do
  {:ok, text} -> text
  {:error, %CompletionError{} = failure} ->
    # Safe for normal inspection and JSON encoding.
    CompletionError.safe_metadata(failure)
end
```

The same configuration works with `gateway.complete/4`,
`gateway.complete_object/4`, `Broker.generate_response/4`, and
`Broker.generate_object/4` for OpenAI, Ollama, and OMLX. Sessions opt in with
`ChatSession.send(session, query, recovery: [])`. On failure the original session
remains available to its caller; failure does not append an assistant response.
The existing `ChatSession.send/2` remains available.

Supported recovery options are `max_attempts: 1` and an `observer` function of
one argument. `recovery: []` enables the default one-attempt contract. `nil`
disables it. Unsupported options, including attempts greater than one, are
ineligible protocol errors with zero wire attempts and empty history. They fail
before HTTP dispatch. Ordinary and structured generation preserve provider
payloads and return values. Existing provider controls and adaptation remain
unchanged; recovery options are client metadata and never enter the payload.

## Safe errors and lifecycle

`CompletionError` exposes category, provider, operation, HTTP status, validated
provider code/request ID, Retry-After, phase, acceptance, observed and delivered
progress, eligibility/reason, resend permission, logical/attempt UUIDs, one-based
wire count, and one-entry failure history. Retry eligibility describes the error;
`resend_permission: :not_granted` means no resend is authorized or performed.
Unrecognized transport causes are ineligible. Connection refusal evidenced by
Mint identifies `connecting` and acceptance `no`; ambiguous failures retain
`unknown`. A received HTTP failure does not establish termination of inference.
A malformed 200 response is decoding failure, with no delivered semantic output.

Progress separates headers and raw body bytes from observed and delivered
reasoning/content/tool calls. Failed decoding can observe semantic text without
delivering it. Non-streaming requests have no delivered tool fragments. The
transport preserves raw response bytes for opt-in calls instead of allowing Req
to decode and re-encode JSON, so byte counts and retained HTTP causes are exact.

Provider metadata accepts one `x-request-id` header and an error object's string
`code`. Both must be 1–128 ASCII token characters (letters, digits, `_`, `.`, `:`,
`-`); invalid/ambiguous IDs are absent. Retry-After is `:absent`, `:invalid`,
`{:delay_seconds, integer}`, or `{:http_date, UTC_ISO8601_string}`. Dates are
validated; no clock-based delay calculation or sleeping occurs in this increment.
JSON and `safe_metadata/1` represent the tuple as a map with `kind` and `value`.

Default `Inspect`, Jason encoding, safe metadata, and lifecycle events omit
payloads, response text, tool arguments, and raw causes. The original cause is
retained behind an opaque function and available explicitly with
`CompletionError.cause(failure)`. That API is unsafe to log without caller review.
Generic VM term dumps are not a supported safe serialization API; use Jason or
`safe_metadata/1`. Opt-in broker traces redact message, content, metadata, tool
argument and result fields, plus model and unvalidated provider evidence, while
preserving the actual tool loop and payload. OpenAI adaptation logs contain only
a stable warning for opt-in calls, excluding the requested model.
Legacy traces retain their previous behavior. oMLX's existing structured-output
warning remains in successful response metadata; opt-in calls suppress its raw
warning log. Applications remain responsible for logs produced by their tools
and explicit callbacks.

Successful requests emit `attempt_started`, `attempt_succeeded`. Failed wire
requests emit `attempt_started`, `attempt_failed`, `exhausted` (or `cancelled`
for a transport-reported cancellation), with matching
identities, wire count, phase and progress. No admission, delay, or retry events
are fabricated. Req retry and redirect are disabled only for opt-in completion
POSTs; model listing, embeddings, model actions, streaming, and realtime remain
outside this increment.

## Assertion-bearing evidence

`test/mojentic/llm/recovery_test.exs` instantiates every adapter × operation below.
Names are prefixed with the gateway module and `complete` / `complete_object`.
The scripted Mox boundary implements the actual `Mojentic.HTTP` behaviour.
Every request asserts endpoint, full decoded JSON payload, headers and retry/
redirect options. Provider identifiers are compared to their exact received
values, not masked aliases.

| Case | Assertion-bearing test suffix | Public entrypoints |
| --- | --- | --- |
| 429/503/504, permanent 400/401 | `HTTP status matrix preserves exact metadata and safe lifecycle` | All adapters' `complete/4`, `complete_object/4` |
| Invalid JSON, structured invalid content, observed versus delivered reasoning/content | `rejects malformed responses and retains parser causes` | All six gateway paths |
| Connection refusal, ambiguous closed connection, timeout | `preserves original transport causes with evidence based phases` | All six gateway paths |
| Seconds/date/invalid/absent/duplicate Retry-After; valid/invalid request ID and code | `validates absent invalid and date metadata` | All six gateway paths |
| Unsupported options, no dispatch | `unsupported recovery options dispatch no HTTP request` | All six gateway paths |
| Equal successful responses and exact unchanged payloads | `opt in success matches legacy successful response and payload` | All six gateway paths |
| Legacy HTTP/body and transport tuples | `retains legacy HTTP and transport errors` | All six gateway paths |
| No tools on failed completion; unchanged caller/session history | `broker response generate object and session failures never execute tools or alter caller history` | All adapters via `Broker.generate_response`, `generate`, `generate_object`, `ChatSession.send` |
| Failure after one real tool execution; tool-result messages retained; no replay | `a failure after one tool executes preserves tool result and does not replay it` | All adapters via recursive `Broker.generate/4` |
| Safe JSON/inspection/logs/lifecycle, explicit original cause | Status matrix and transport tests above | All six gateway paths |
| Provider errors inside a 200; parser exceptions with unsafe messages | `provider response and parser exceptions stay private` | All six gateway paths |
| Transport-reported cancellation and unknown transport causes | `cancellation and unknown transport causes are ineligible` | All six gateway paths; cancellation scheduling is unimplemented |
| Success lifecycle and semantic progress | `success events distinguish observed and delivered semantic progress` | All six gateway paths |
| Observed tool calls on malformed structured content are not delivered | `structured failure records observed completed tools without delivering them` | All three adapters' `complete_object/4` |
| Tool iteration budget stays at one across recursive requests | `tool depth remains bounded when recovery errors are enabled` | OpenAI via shared broker loop |
| Raw warning header on invalid structured object | `oMLX structured parsing does not log warning headers on malformed object content` | OMLX `complete_object/4` |
| Requested model omitted from adaptation logs | `OpenAI parameter adaptation logs exclude the requested model and payload` | OpenAI `complete/4` |

`test/mojentic/llm/recovery_wire_test.exs` uses a supervised local TCP server
through the production Req client, with a queued 200 response that would expose
an accidental hidden resend:

| Test suffix | Evidence |
| --- | --- |
| `Req sees one exact request and never retries a 503` (all six paths) | 503 stays a failure; exact HTTP route, credential header, message/model JSON, raw response bytes, request ID, Retry-After and received requests |
| `broker and session tracing omit payload and response secrets on completion failures` | Actual broker/session Req requests with a real tracer; sentinel payload/body absent from recorded events |

The initial public OpenAI probe failed on missing `retry: false` and subsequently
passed after the implementation. `.foundry/proof.json` records actual exit codes
and capture logs; those logs also point to Foundry's full stdout/stderr artifacts.

## Capability and remaining contract cases

| Completion adapter | Single-attempt safe errors | Provider termination evidence | Idempotency | Resends / streaming recovery |
| --- | --- | --- | --- | --- |
| OpenAI | Ordinary and structured, tested | Unknown | Not implemented | Not implemented |
| Ollama | Ordinary and structured, tested | Unknown; model presence does not prove termination | Unsupported in this increment | Not implemented |
| oMLX | Ordinary and structured, tested through its own parser | Unknown; load/unload is not admission evidence | Unsupported in this increment | Not implemented |

Unimplemented: 503-then-success recovery, persistent-504 multi-attempt exhaustion,
backoff/jitter/delay ceilings, Retry-After clock calculations, recovery deadlines,
status/category policy selection, asynchronous admission, cancellation during
request/admission/backoff, interrupted streams, keepalive-only progress,
immutable multi-attempt payload checks, retry identities and histories beyond
one attempt, explicit wire trace observer APIs, and cross-port parity. Embeddings
and realtime voice are separate APIs. No unverified parity is claimed.

## Validation

Final focused suite: **80 tests, zero failures**. Full suite: **22 doctests,
918 tests, zero failures**, with 19 existing integration exclusions. Coverage is
**88.36%**, above the unchanged **80%** threshold. No exclusions or thresholds
were added or lowered. The focused and full results are in
`.foundry/logs/recovery-tests.log`, `test.log`, and `coverage.log`.

| Command | Result | Evidence under `.foundry/logs/` |
| --- | --- | --- |
| `mix format --check-formatted` | Exit 0 | `format.log` |
| `mix compile --warnings-as-errors` | Exit 0 | `compile.log` |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0 | `compile-test.log` |
| `mix credo --strict` | Exit 0, no issues | `credo.log` |
| `mix test` | Exit 0 | `test.log` |
| `mix test --cover` | Exit 0, 88.36% | `coverage.log` |
| `mix deps.audit` | Exit 0, no vulnerabilities | `deps-audit.log` |
| `mix hex.audit` | Exit 0, no retired/security advisory packages | `hex-audit.log` |
| `mix sobelow --config` | Exit 0, no findings with the existing configuration | `sobelow.log` |
| `mix docs` | Exit 0 | `docs.log` |
| `mix hex.outdated --all` | Exit 1, outdated packages; visibility only | `hex-outdated.log` |
| `mix dialyzer` | Unavailable: task not found, exit 1 | `dialyzer.log` |

Commands ran through `foundry capture` with `/tmp/mojentic-mix`, a wrapper
selecting the installed Elixir 1.18.5 / OTP 28.5.0.7 toolchain and writable
`HEX_HOME=/tmp/mojentic-recovery-hex`. `toolchain.log` records the actual runtime.
Each local log contains captured output and the full Foundry artifact paths.

MixAudit's attempted advisory database refresh encountered a read-only filesystem.
Its database revision `935abf7410a2bbb18e12579dee6e31267c3ed244` was independently
compared with upstream main using read-only commands and matched exactly; see
`advisory-local.log` and `advisory-remote.log`. No repository refs were changed.
Sobelow emitted lockfile keyword parsing warnings, without security findings.
The outdated package report is not a vulnerability finding; dependencies were
not updated. Dialyxir is absent from this project, so Dialyzer and its PLT cache
are unverified. Adding a dependency would violate this increment's scope.
There is no configured `mix precommit` alias.

No dependency updates, Elixir/OTP version-line bumps, generation finish changes,
or releases are part of this increment. CI is pinned to exact Elixir 1.18.5 and OTP 28.5.0.7
within the existing 1.18/28 lines.
