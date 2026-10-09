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
Req identifies `connecting` and acceptance `no`; ambiguous failures retain
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
| 429/500/502/503/504, permanent 400/401 | `HTTP status matrix preserves exact metadata and safe lifecycle` | All adapters' `complete/4`, `complete_object/4` |
| Invalid JSON, structured invalid content, observed versus delivered reasoning/content | `rejects malformed responses and retains parser causes` | All six gateway paths |
| Connection refusal, ambiguous closed connection, timeout | `HTTP boundary preserves transport causes including synthetic unreachable and reset reasons` | All six gateway paths |
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
| `Req sees one exact request and never retries HTTP STATUS` (all six paths, seven statuses) | 503 stays a failure; exact HTTP route, credential header, message/model JSON, raw response bytes, request ID, Retry-After and received requests |
| `broker and session tracing omit payload and response secrets on completion failures` | Actual broker/session Req requests with a real tracer; sentinel payload/body absent from recorded events |

The preserved increment's initial probe established disabled Req retries. This
correction replaces the proof artifact with a real production closure probe,
described below; its failure tests classification rather than a marker toggle.

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

## Production boundary correction (2026-10-09)

`CompletionRequest` now recognizes the `Req.TransportError` returned unchanged
by production `ReqClient`. The original Mint, atom, and tuple boundary forms
remain compatible. Only opt-in classification changed; legacy Req defaults and
adapter parsers are preserved.

The proof-first closure probe read the entire HTTP request before closing the
socket. The original classifier rejected the expected stable reason and
eligibility (exit 2); the corrected classifier passed (exit 0).
`.foundry/proof.json` records those commands and logs. Closure and receive timeout
prove neither termination nor nonacceptance: phase and acceptance remain unknown,
and resend permission stays `not_granted`. Timeout is ineligible. Refusal alone
establishes connecting/nonacceptance. No transport error exposes payload or
credentials through normal error serialization or observer/history metadata.

Fresh deterministic tests in `test/mojentic/llm/recovery_wire_test.exs`:

| Exact test suffix (prefixed by adapter and operation) | Public paths and evidence |
| --- | --- |
| `Req closure retains ambiguous acceptance and exact cause` | All six `complete/4` and `complete_object/4` paths; real Req `:closed`, full semantic JSON, recorded request, exact progress/history, correlated event/error UUIDs |
| `Req receive timeout preserves uncertainty without resend` | All six paths; server retains an accepted socket without responding; real Req `:timeout`, complete recorded payload and unchanged uncertainty |
| `Req connection refusal proves nonacceptance` | All six paths; bound non-listening local port, real Req `:econnrefused`, exact cause and metadata |
| `Req sees one exact request and never retries HTTP STATUS` | All six paths for STATUS 429, 500, 502, 503, 504, 400, 401; queued success exposes hidden resends; actual route, request JSON and raw response |
| `real Req closure propagates through broker APIs and session with caller history intact` (adapter prefix only) | All three adapters through `Broker.generate/4`, `generate_response/4`, `generate_object/4`, `ChatSession.send/3`; exact request list and semantic payloads, original cause and correlated history/events, unchanged caller history |

`RecoveryTest`'s `HTTP boundary preserves transport causes including synthetic
unreachable and reset reasons` explicitly supplements the real fixtures with
Mox HTTP-behaviour tests for Req `econnreset`, `enetunreach`, `ehostunreach`, and
an unknown reason. These are synthetic boundary evidence, not production wire
proof. Existing Mint causes are compatibility evidence only. All six
`Req transport boundary preserves exact legacy wrapper` tests verify the exact
retained Req cause under the legacy `request_failed` wrapper. The HTTP metadata
matrix now includes 500 and 502. Existing malformed/provider/unsupported-options,
legacy success and adapter parsing tests remain in place. Tool safety tests assert
exact assistant call IDs/arguments and serialized existing tool results; execution
occurs once, and the existing bounded-depth test stays unchanged.

CI already consistently pins Elixir **1.18.5** and OTP **28.5.0.7** across all
setup steps. The installed toolchain matches those versions; supported version
lines, package/dependency versions, thresholds, and exclusions were not changed.
Dialyxir is absent; adding it or changing CI for a nonexistent PLT would exceed
this correction's dependency freeze. No precommit alias is configured.

The clean initial HEAD was `380dc6e`, exactly the preserved c1 ref. Git fetch was
attempted before coding and rejected by the read-only shared Git directory.
Read-only `git ls-remote origin refs/heads/main` returned `59dc123`, matching local
origin/main and the merge base with HEAD. No divergent remote changes were found.
No refs were changed; Foundry owns finalization. The coordinator's release
instructions and all other existing edits remain preserved; no release was made.

## Fresh validation

Focused suite: **159 tests, zero failures**. Full suite: **22 doctests,
981 tests, zero failures**, with the existing 19 integration exclusions.
Coverage: **88.37%**, above the unchanged **80%** threshold. No exclusions or
thresholds were added or lowered.

| Command | Result | Log in `.foundry/logs/` |
| --- | --- | --- |
| `mix format --check-formatted` | Exit 0 | `format.log` |
| `mix compile --warnings-as-errors` | Exit 0 | `compile.log` |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0 | `compile-test.log` |
| `mix credo --strict` | Exit 0, zero issues | `credo.log` |
| `mix test` | Exit 0 | `test.log` |
| `mix test --cover` | Exit 0, 88.37% | `coverage.log` |
| Focused recovery/config tests | Exit 0 | `recovery-tests.log` |
| `mix deps.audit` | Exit 0, no vulnerabilities in checked database | `deps-audit.log` |
| `mix hex.audit` | Exit 0, no retired/security advisory packages | `hex-audit.log` |
| `mix sobelow --config` | Exit 0, no findings under existing configuration | `sobelow.log` |
| `mix docs` | Exit 0 | `docs.log` |
| `mix hex.outdated --all` | Exit 1, outdated packages, informational | `hex-outdated.log` |
| `mix dialyzer` | Exit 1, task unavailable | `dialyzer.log` |

All Mix commands ran through `foundry capture` with `/tmp/mojentic-mix`, selecting
the installed pinned toolchain and writable `HEX_HOME=/tmp/mojentic-recovery-hex`.
`toolchain.log` records the actual Elixir/OTP runtime. Logs retain the actual
capture exit code and full stdout/stderr artifacts. Dependencies were restored
from the existing lockfile; no package versions changed.

MixAudit's advisory refresh attempted a write in its read-only shared database.
The local database commit was independently compared to upstream main through
read-only commands; see `advisory-local.log` and `advisory-remote.log`. Sobelow
emitted existing lockfile keyword parsing warnings without security findings;
this is not a Phoenix project. Dependency compilation emitted upstream warnings;
project compilation and strict Credo passed. No advisory suppressions were added.
Dialyzer/PLT analysis remains unavailable and is not claimed as passing.

Changes remain uncommitted for Foundry review and finalization. No main landing
or release is claimed. The broader recovery mission gaps listed above remain
explicitly unimplemented.
