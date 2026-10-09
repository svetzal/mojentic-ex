# Completion recovery conformance: Elixir streaming increment

This increment retains the delivered non-streaming recovery at
`a985c7b7303cecd0b864f697f8a4099b2e1522d9` and adds opt-in streaming recovery
under TRANSIENT-RECOVERY-2026-10.md and RECOVERY-REQUEST-2026-10.txt sections 1–5.
Recovery-disabled adapters retain their existing parsers, timeout behavior and
payloads. No dependencies, runtime pins, ordinary completion parsing, embeddings,
realtime, model management, tool depth, release files or sibling repositories
were changed. Exact raw wire trace hooks remain a separate increment.

## Synchronization correction

This correction starts from the preserved c7 streaming increment at
`55390244b01402d62664b0849764618f819245ec`
(`foundry-task/mojentic-ex-mojentic-ex-transient-recovery-v1-c7-7afd22`).
The initial working tree was clean; its empty binary diff was saved before work.
AGENTS.md was copied for preservation and remains byte-for-byte unchanged,
including the coordinator's release authorization. No release work is authorized
in this Foundry correction.

`git fetch --dry-run --no-write-fetch-head origin main` was actually attempted
and exited **0**. It contacted origin without writing refs or FETCH_HEAD. The
later Foundry restriction prohibits rebasing and modifying refs, so
`pull --rebase origin main` was not run. This is a successful dry-run fetch,
not a completed pull/rebase. No conflicts arose or were resolved.
`git ls-remote origin refs/heads/main` exited **0**, reporting remote main at
`a985c7b7303cecd0b864f697f8a4099b2e1522d9`.
`git rev-list --left-right --count HEAD...origin/main` exited **0**, returning
**2 0**. Actual synchronization evidence is in
`.foundry/logs/synchronization.log`. No refs were changed; Foundry owns
finalization and all source changes remain uncommitted in this worktree.

## Characterized boundaries and licensed changes

Before changing production source, the real Req fixture demonstrated that
OpenAI's terminal stream delivered partial content and then returned a legacy
request failure, without the required structured interruption/progress.
`OpenAILegacyStream` owns a suspended HTTP continuation; legacy Ollama repeatedly
enumerates its HTTP stream. `TerminalEventStream` owns one continuation and
requires provider terminal proof. oMLX shares the OpenAI parsers. Terminal APIs
supply no tools and suppress reasoning. Broker streaming accumulates completed
tools, executes them on stream completion, and normally logs then drops adapter
errors. ChatSession normally collects strings before finalization. Req normally
discards non-2xx headers and uses an absolute stream deadline. These paths remain
in place with recovery disabled; the existing suite characterizes compatibility.

Recovery-enabled adapters freeze the encoded body, endpoint and headers once,
then use `StreamRecovery` to own each HTTP continuation. Recovery reuses the
existing bounded admission/backoff policy. Streaming HTTP metadata retains
status, validated request ID and Retry-After, including after a partial-body
failure. Finch's streaming transport wrapper is classified at this boundary
without changing ordinary completion classification.

Observed semantic progress is counted before parsing/delivery. Delivered
progress is acknowledged with the recovery owner before returning the event to
the enumerator, so cancellation cannot lose already delivered content. Reasoning
suppressed by terminal APIs remains observed but undelivered. Keepalive bytes
increase only raw progress. Tool fragments are buffered; incomplete arguments
never become executable calls. Completed legacy calls are delivered once, but a
wire failure before terminal proof prevents broker execution. Once any semantic
output has been observed, retry eligibility cannot authorize replay.

A recovery worker owns only its request workers and owner monitor. Cancellation
covers connection/header waits, active streaming, admission and backoff. Consumer
halt and consumer process death close locally owned sockets and workers. Socket
closure does **not** establish remote inference termination. Active generation
has idle receive waits and no total generation deadline; recovery deadlines guard
new dispatch/admission/backoff rather than truncate an active generation.

The broker propagates opt-in errors and reasoning events. Follow-up recovery
never repeats a completed tool effect or resets tool depth. ChatSession's opt-in
`send_stream/3` records failed/halted status; `finalize_stream/1` returns the error
without adding a successful assistant response. Its accumulation handle must be
finalized to release the handle process, as with legacy session streaming.

Default broker payload tracing is suppressed for recovery-enabled streaming.
Lifecycle metadata, error inspection and JSON serialization omit request text,
response text, tool arguments, credentials and raw causes. Original causes remain
available only through `CompletionError.cause/1`. No unsafe observer is installed
by default.

## Proof first

Before changing production code, expanding documentation or running full gates,
six new public-boundary probes exercised the remaining completed-tool loss through
the production ReqClient and deterministic scripted TCP responses. The cases are
`#{gateway} #{entrypoint} retains fragmented completed tools before observation failure`,
for OpenAI, Ollama and oMLX, with `adapter` invoking `complete_stream/4` and
`broker` invoking `Broker.generate_stream/4`.

The first chunk delivers sentinel content and starts two tool argument fragments.
The test waits for actual delivery before releasing a second chunk containing both
argument suffixes, their completion marker, then `tool_calls: 7`. Each case asserts
exactly four observed fragments and two completed calls; zero delivered fragments
or completed calls; unchanged previously delivered content; actual raw bytes;
one server-observed wire request; no tool execution or successful terminal;
explicit protocol interruption; and matching progress and actual logical request
and attempt identities in the final error, history and failure lifecycle records.

All six probes rejected the preserved production source (actual exit **2**): it
reported zero completed calls instead of two. All six pass after the correction
(actual exit **0**). `.foundry/proof.json` records the commands and complete logs
in `rejecting.log` and `corrected.log`. An earlier prerequisite invocation exited
**1** because dependencies were absent; it is not the behavioral rejection.
Dependencies were restored using the unchanged lockfile, without upgrades.

Legacy streaming now observes and assembles each frame before advancing to the
next frame. A later observation exception retains already assembled completed
calls and fragment counts. Parsing remains atomic for chunk delivery, so none
of the failing chunk's tools or terminal events reach the adapter or broker.
Earlier acknowledged content remains delivered. EOF uses the same frame path;
terminal-event APIs retain their observation and parsing contract. Existing
parsing-failure, EOF, privacy, cancellation, payload and broker/session safety
regressions remain intact. Recovery-disabled behavior is unchanged.

## Named production-HTTP cases

`test/mojentic/llm/stream_recovery_wire_test.exs` uses the production ReqClient and
scripted TCP responses through public adapter, broker and session entrypoints.
The complete traced cases and results are in `.foundry/logs/stream-cases.log`.
The six-path matrix covers OpenAI, Ollama and oMLX `complete_stream/4` and
`complete_stream_events/3` independently.

| Named case suffix | Verified assertions |
| --- | --- |
| `recovers 503 with immutable full payload and exact lifecycle` | Complete server-observed request equality, messages, Retry-After delay, received headers, all eight lifecycle events and exact wire/logical IDs |
| `persistent failures preserve exact bounded identities and histories` | Three identical server requests, fifteen lifecycle events, three distinct attempt IDs, one logical ID and exact history correspondence |
| `partial content cannot replay or execute incomplete tools` | Exact raw bytes and observed/delivered progress; explicit interruption, original cause, one request and no successful terminal |
| `partial reasoning cannot replay or execute incomplete tools` | Delivered reasoning for legacy APIs; observed-only reasoning for terminal APIs; no replay |
| `partial tools cannot replay or execute incomplete tools` | Observed fragments, zero delivered fragments/calls, no execution/retry; terminal APIs preserve their intentional unexpected-tool protocol rejection |
| `keepalive bytes recover without semantic progress` | Nonzero raw bytes, zero semantic progress, two identical requests and complete lifecycle |
| `pending admission allow/reject is asynchronous and never counts as a wire attempt` | One request while pending; explicit allow preserves payload; reject prevents resend; exact lifecycle and identities |
| `ambiguous local failure requires admission by default` | Ollama/oMLX acceptance remains unknown and no second request is authorized |
| `cancellation during active/admission/backoff sends no subsequent request` | Original HTTP failure retained when present, cancellation evidence, exact phase-specific lifecycle and one server request |
| `cancellation after delivery preserves exact semantic and raw progress` | Delivered content acknowledged before cancellation, exact bytes and closed live socket |
| `Retry-After ceiling refuses resend and preserves original HTTP failure` | 429 and parsed delay retained; configured ceiling prevents a second request |
| `HTTP 400/401 cannot become retryable through caller selection` | Explicit status selection cannot bypass unsafe streaming failure classification |
| `consumer halt closes owned HTTP and recovery workers` | Public consumer takes one event; server observes socket closure and one request |
| `consuming process death closes its live socket` | Monitored consumer termination closes its server-observed socket without touching unrelated work |
| `recovery deadline is not a total active generation timeout` | Injected clock passes deadline during an active held request; successful release still completes with one request |
| `broker default tracing and lifecycle serialization exclude sentinel payloads` | No payload trace entries; sentinel request/response/credential values absent from errors, JSON, events and logs |
| `broker executes completed tool once then propagates follow-up interruption` | Exact tool arguments/result in follow-up payload, one execution, immutable retry payload, eleven lifecycle events and exact request/history identities across two semantic interactions |
| `session refuses to finalize partial output after a completed tool` | Concrete tool effect once, consumer receives failure, finalization returns that failure and original immutable history remains unchanged |
| `broker recovery does not replenish streaming tool depth` | One tool execution; recovered second completion still exhausts depth one |
| `completed tool deltas followed by wire failure expose progress without execution` | OpenAI/oMLX observed/delivered completed-call counts, exact bytes and no tool execution before terminal proof |
| `final frame without newline retains exact raw byte count` | Ollama legacy and terminal APIs accept the actual EOF frame without counting synthetic bytes |

Terminal-event APIs deliberately do not execute tools. Their unexpected-tool
error is the original parser failure; they stop at that failure rather than read
a later transport failure. Ollama's atomic final tool frame completes its legacy
request; completed-call followed-by-wire-failure is separately exercised for the
OpenAI-compatible protocols where terminal proof still requires `[DONE]`.

## Correction cases and public paths

All cases use scripted HTTP fixtures and the production `Mojentic.HTTP.ReqClient`.
No gateway mock or live-model request establishes this correction's evidence.

| Named case suffix | Public paths and assertions |
| --- | --- |
| `broker failing tool protects default observability without replay` | OpenAI, Ollama and oMLX `Broker.generate_stream/4`; one completed failing tool invocation, exactly two HTTP requests, unchanged user and tool-result messages, distinct logical follow-up identity, default logs/tracer records/safe error representations/lifecycle events exclude all sentinels |
| `legacy parser exception retains same-chunk semantic observations and bytes` | OpenAI `complete_stream/4`; content, reasoning and tool fragments before malformed arguments, exact 378 bytes, no delivered output, interruption and one failure history entry |
| `observation exception retains valid same-chunk semantics` | All three providers, `complete_stream/4` and `complete_stream_events/3`; valid content/reasoning/tool frames before malformed tool data, exact raw bytes and independently specified observed versus delivered progress, exact identities/history/lifecycle, no resend or successful terminal |
| `parser exception preserves previously delivered output` | All six completion paths; server releases malformed chunk only after public content delivery, exact cumulative bytes, prior content remains delivered while later reasoning is observed only, interruption/history/lifecycle retain progress |
| `legacy parsing exception preserves completed but undelivered tools` | All three `Broker.generate_stream/4` paths; valid completed tool frame before malformed arguments in the same chunk, one observed completed call and zero delivered/executed calls, exact raw bytes and no successful terminal |
| `retains fragmented completed tools before observation failure` | All three `complete_stream/4` and `Broker.generate_stream/4` paths; two calls assembled across held HTTP chunks, exact four fragments/two completions, preserved earlier delivery, zero tool delivery/execution, actual bytes, one request, protocol interruption and exact error/history/lifecycle identity correspondence |
| `EOF observation exception retains progress without synthetic bytes` | Ollama both completion APIs; malformed final frame without newline, prior content and applicable reasoning delivery retained, actual bytes only, one request and interrupted error |

Terminal-event APIs do not support tool execution; their malformed-frame cases
verify progress without adding that capability. Existing ordinary/structured
recovery, recovery-disabled adapter/broker tests, follow-up payload equality and
streaming tool-depth tests remain intact and are included in the full suite.

## Capability limits

`Recovery.capabilities/1` reports local request cancellation supported and remote
cancellation, request status and idempotency unsupported, with exact remote
termination unknown, for all three providers. Local ambiguity needs explicit
application admission. There is no model unload, tool/session replay, agent
restart, harness policy or live-model experiment in this increment. Exact wire
trace hooks remain unavailable and are not represented by lifecycle counts or
masked-ID evidence. Deterministic fixture equality verifies the semantic payload;
it does not establish provider-side idempotency or remote termination.

## Final validation

All commands used `foundry capture` and `/tmp/mojentic-mix`, selecting unchanged
CI-pinned Elixir **1.18.5** and OTP **28.5.0.7**. Runtime selection was verified
with `mix --version` and the installed OTP_VERSION file. Full stdout/stderr are
included in each gate log. No package/runtime pins, coverage threshold,
exclusions or advisory suppressions changed.

The final full suite passes **22 doctests and 1,337 tests**, zero failures,
with the existing **19 integration exclusions**. Coverage is **89.05%**, above
the unchanged **80%** threshold. The production-HTTP file passes **159 cases**.
The final focused proof passes all **six** new cases (153 others excluded).
Strict Credo initially rejected two single-clause `with` expressions (exit
**4**, `credo-initial.log`). Converting them to `case` resolved the findings
without suppressions; all required checks were rerun successfully.

| Command | Actual exit | Log in `.foundry/logs/` |
| --- | --- | --- |
| `mix format --check-formatted` | 0 | format.log |
| `mix compile --warnings-as-errors` | 0 | compile.log |
| `MIX_ENV=test mix compile --warnings-as-errors` | 0 | compile-test.log |
| `mix credo --strict` | 0 | credo.log |
| `mix test --cover` | 0 | coverage.log |
| `mix test` | 0 | test.log |
| `mix deps.audit` | 0 | deps-audit.log |
| `mix hex.audit` | 0 | hex-audit.log |
| `mix sobelow --config` | 0 | sobelow.log |
| `mix hex.outdated --all` | 1 | hex-outdated.log |
| `mix dialyzer` | 1 | dialyzer.log |
| `mix docs` | 0 | docs.log |
| `mix test test/mojentic/llm/stream_recovery_wire_test.exs --trace` | 0 | stream-cases.log |
| `mix test test/mojentic/llm/stream_recovery_wire_test.exs --only completed_observation_proof --trace` (preserved source) | 2 | rejecting.log |
| `mix test test/mojentic/llm/stream_recovery_wire_test.exs --only completed_observation_proof --trace` (final source) | 0 | corrected.log |

MixAudit reports no vulnerabilities, but its advisory refresh failed on a
read-only FETCH_HEAD. Independent read-only checks exited **0**, confirming
local HEAD and upstream main both at
`935abf7410a2bbb18e12579dee6e31267c3ed244` (`advisory-local.log` and
`advisory-remote.log`). The refresh itself is not claimed as successful.
Hex audit reports no retired or security-advisory packages. Sobelow completes
with no security findings and existing quoted-keyword lockfile warnings;
this is not a Phoenix application.

`mix hex.outdated --all` reports available upgrades (informational, exit **1**).
Dialyzer exits **1** because its task is unavailable: Dialyxir is absent.
Dialyzer and its PLT/cache prerequisites are **not** claimed as passing; adding
that dependency or changing CI is outside this correction. No precommit alias
exists. Docs build succeeds with existing missing LICENSE/igniter usage-rule
references and private TracerEvent type-reference warnings outside this scope.
Streaming, broker and session guides were reviewed; their public contracts
remain aligned. Only conformance evidence required documentation changes.

`.foundry/proof.json` records the rejecting and passing behavioral probes.
`.foundry/logs/proof-validation.log` validates JSON fields and types, actual
captured exit codes, all gate logs, and unchanged AGENTS.md. The completed
source, tests and conformance changes remain in the working tree for Foundry
review and finalization; no commit, push, merge, rebase, tag or release occurred.
