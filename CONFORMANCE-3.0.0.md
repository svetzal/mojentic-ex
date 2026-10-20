# 3.0.0 conformance

## Current offline readiness assessment

This assessment covers RELEASE-3.0.0 parts 1–5 on base commit
`067831fbcd69c4b95567504db50ecf5d294a0e6e` plus the uncommitted deterministic
crash-handler test correction. A read-only remote check and local refs confirm
that the worktree starts at current `main`. Current manifest identities and
source/packaged verification results are recorded in
[offline verification](audit/offline-verification.md).

The scanner uses host `find`/`grep` and rejects direct calendar clocks as well
as monotonic clocks, sleeps, sockets and downloads. Its command regression runs
without ripgrep. The shared test helper rejects Finch connection attempts across
each complete suite, including the fresh packaged consumer. Streaming ReqClient
still creates lazy Finch pool supervisors before using the in-process Req adapter;
those pools do not establish connections.

Stacey's October 19 decision authorizes internal clock injection. `Mojentic.Clock`
now supplies monotonic time, UTC time, OS timestamps and sleeping behind an internal application
configuration seam. Its production default calls the same BEAM clocks and sleeper;
the suite installs a fixed clock and explicitly advances a shared counter when
needed. Existing per-request clock options retain precedence. Public APIs,
dependencies, runtime pins, versions and CI wiring are unchanged.
The remaining native-tool timeout test now injects the internal scheduling
boundary `Mojentic.TaskStream`; production delegates unchanged to
`Task.async_stream/3`. The public `ParallelToolRunner.run_with/4` case waits for
its real tool worker to start, explicitly kills it, verifies the monitored
`:killed` exit, and delivers `{:exit, :timeout}` without running a timer. It
asserts retained call identity and exactly one completion callback. The case is
included in the same source and fresh Hex readiness contract set. The suite-wide
audit also removed two 200ms silence windows in the recursive agent's emitter
tests. Those tests now wait for emitter processing, trace delivery and actual
callback exits before checking the mailbox. Remaining receive/await bounds cap
failures, and zero-time probes operate on controlled pending work or queued
messages.

Foundry owns Git finalization; changes remain uncommitted.

The binding root contracts were read and their SHA-256 identities verified:

| Document | SHA-256 |
| --- | --- |
| RELEASE-3.0.0 / initiative brief | `54260316363be7f365161cb734aa33e22bdc1286ef640a7ec532e83f5811fd5f` |
| TRANSIENT-RECOVERY-2026-10, including October 12 amendment and October 18 testing correction | `141d4ee5fcfbc18c940a7e7fe8d5ba9e381abc41a6d03f300f541e0fd5236f9d` |
| REASONING-PROTOTYPE-2026-10 | `0a40f3ad45c593bc779411021e45db569e73d3ecce86c99b201e7f8ebb656809` |
| MODEL-METADATA-2026-10, including October 17 decisions | `d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c` |

The local recovery and MODEL-METADATA copies match the authoritative root bytes. No new ambiguity was found. Library readiness follows the
October 17 self-validation policy: the same versioned executable cases consume
public APIs from source and from the local Hex payload. TypeScript source identities are
provenance. Dependents verify on published-version adoption; this assessment does
not require or claim unreleased dependent adoption, external port execution, live
model efficacy or external provider implementation verification. No running
service boundary is changed by this assessment.

## Shared executable contract and distribution boundary

`test/contracts/readiness_v1.files` selects **ex-readiness-v1**, reusing the existing
ExUnit cases and in-process Req adapter mechanism. Its companion
`readiness_v1.manifest.sha256` identifies all selected cases, fixtures, support,
production modules, package inputs and verification scripts. Both commands check
that same manifest before running those same test files. Current manifest SHA-256:
`deaa3ca0fbf515eb2fdf643a943a6e548ee2854fb17287c30eecf70a74b5ed5d`.

The current first-token manifest SHA-256 is
`ea8fa8a4fc37427e9b5f1306447c3788d40a032fb997eb59fd4d9460726dd220`.

Both source and payload verification use the following commands:

- Source public consumers: `scripts/verify-readiness-contract`.
- Fresh extracted Hex payload consumer: `scripts/verify-packaged-first-token`.

The shared set also includes `test/mojentic/realtime/session_test.exs`:
`interrupted turn with :drop policy discards tool outputs` waits for receipt of
the exact `c3`/Carol batch result for interrupted turn `r2`, then calls public
`Session.subscribe/1` to wait for handler completion. Subscriber events and
in-process transport payloads establish absence of the correlated submission.
A temporary `:submit_completed_only` negative control holds the batch result
until after the tool completion event and worker exit; it exposes the exact
`c3` greeting output and fails the drop assertion. No production change remains.
The same file's `realtime_close stops the session` case uses public
`Session.subscribe/1` and the existing in-process FakeTransport. The transport
holds the original session's close request and identifies both PIDs at cleanup
entry. The same behavioral probe rejects that observed pending-cleanup state
immediately, then accepts completed cleanup after release only with exact
`:normal` DOWN messages for both premonitored PIDs. The rejecting execution
fails on the incomplete-state result, without a forced timeout, and still
releases cleanup and records both normal exits. The corrected execution asserts
both outcomes. Receive bounds cap failure latency; no real sleep, socket or
elapsed-time assertion is used. This proves that delivered server-close can
precede completed cleanup, but does not establish the scheduling or cause of
the historical intermittent packaged failure. Exact diagnostic results, current
manifest hashes, execution identity and both consumer results are recorded in
[offline verification](audit/offline-verification.md).

The second command retains its historical name for gate compatibility. It builds
with `mix hex.build`, records the tar SHA-256, extracts the actual contents, creates
a fresh Mix project with a path dependency on those extracted contents, and
compiles/runs against that package rather than the source tree. Only the support
harness, fixtures and executable tests are copied from the source checkout. The
consumer uses its own build and dependency directory. It does not publish.

The preserved versioned sets are `recovery-capabilities-v1`,
`admission-without-hook-v1`, `admission-without-decision-v1`,
`retry-after-dates-v2`, `omlx-keepalive-v1`, `typed-errors-v1`,
`native-reasoning-v1`, `context-window-v1`, `request-fidelity-v1` and
`ex-stream-first-token-v1` (TypeScript v1 plus additive v2 provenance at
`54171796a2b02c0f0170d0758d2e3c693ad027c9`). The aggregate freezes their actual
executable definitions, not just identifiers or schemas. Wire suites install
production `Mojentic.HTTP.ReqClient` and compare full decoded request bodies,
replay bytes, semantic results and typed failure evidence. Capability declarations
and pure context helpers supplement these wire checks. Mox doubles in pure
metadata-consumer checks derive expected results from `context-window-v1`; their
responses are exercised independently through ReqClient and the Req adapter.

## Part 1: recovery decision-to-test mapping

Paths below are under `test/mojentic/llm/`. Names containing `<...>` denote the
actual generated named cases for every applicable gateway/entrypoint. All are in
the shared source/payload set. The ordinary, structured, event and legacy paths,
Broker and ChatSession cover OpenAI, Ollama and oMLX, the maintained completion
adapters. Embeddings and realtime are explicitly outside completion recovery.

| Binding decision | Named behavioral evidence |
| --- | --- |
| Stable error category/provider/operation, status, optional code/request ID/Retry-After, phase, acceptance, progress, identity, bounded history and private cause | `recovery_test.exs`: `<gateway> <operation> HTTP status matrix preserves exact metadata and safe lifecycle`; `recovery_wire_test.exs`: `<gateway> <operation> real Req persistent 504 exhausts with ordered exact evidence`; `provider_metadata_wire_test.exs`: `<gateway> <operation> <fixture> preserves safe metadata and immutable wire retries` |
| Default recovery off; one attempt; legacy success/error compatibility; opt-in APIs | `recovery_test.exs`: `<gateway> <operation> opt in success matches legacy successful response and payload`, `retains legacy HTTP and transport errors`; `admission_wire_test.exs`: `<gateway> <entrypoint> no hook <scenario> preserves wire and lifecycle contract` |
| Eligible transport and 429/500/502/503/504, caller category/status selection, permanent/protocol veto | `recovery_wire_test.exs`: `<gateway> <operation> real Req 503 recovers with identical full payload and correlated lifecycle`, `real Req permanent failure does not retry under bounded recovery`; `permanent_http_wire_test.exs`: `<gateway> <operation> selected <status> <body_mode> tracing <tracing> remains permanent`; `stream_recovery_wire_test.exs`: interrupted public streams and selected-status truncated failures |
| Full jitter exponential ceiling and saturation, Retry-After minimum, ceiling/budget refusal, budget begins at first failure; active generation may finish | `recovery_wire_test.exs`: `real Req exponential full jitter doubles and saturates at the configured ceiling`, `real Req monotonic budget begins at first failure and never resets on later failures`, `<gateway> <operation> recovery deadline allows active generation to finish`; `retry_after_dates_wire_test.exs`: `<gateway> <entrypoint> <form> <scenario> normalizes metadata and enforces wire recovery limits` |
| Admission distinguishes eligibility from permission; pending is not an attempt; no timeout proves remote termination | `recovery_wire_test.exs`: `ambiguous local 504 waits for explicit admission and preserves complete wire payload`, `<gateway> <operation> real Req pending admission requires explicit <decision>` |
| Cancellation during request/admission/backoff; no later dispatch; observed versus delivered evidence; paused-consumer cleanup | `recovery_wire_test.exs`: `<gateway> <operation> cancellation inside retry worker guard retains only dispatched failure` (retry_started selects the worker, monitor handshake precedes cancellation, DOWN must be :killed, exact single request and original HTTP history); `<gateway> <operation> real Req cancellation during <phase> is authoritative and sends no retry`; `cancellation_socket_wire_test.exs`: `<gateway> <operation> tracing <tracing> <stage> closes correlated response before fixture release`, `paused consumer cancels a buffered terminal before success` |
| Immutable messages/native history/tools/schema/model/sampling/limits on retries, including file inputs | `immutable_request_wire_test.exs`: `fidelity-v1 <gateway> <boundary> <operation> <row> exact body and admitted replay`; `recovery_wire_test.exs`: `<gateway> <operation> recovery freezes legacy adaptation of history schema tools and controls` |
| Semantic reasoning/content/tool fragments or completed calls forbid replay; bounded failure/exhaustion never completes a session | `stream_recovery_wire_test.exs`: `<gateway> <mode> cancellation after delivery preserves exact semantic and raw progress`, `<gateway> completed tool deltas followed by wire failure expose progress without execution`; `typed_errors_wire_test.exs`: `<gateway> <entrypoint> <scenario> retains typed cause and forbids replay` |
| Tools execute once; retry does not restart agent/Broker or replenish depth | `recovery_wire_test.exs`: `<gateway> <caller> real Req recovers after exact tool result without tool replay`, `real Req recovery does not replenish broker tool depth`; `stream_recovery_wire_test.exs`: `<gateway> broker recovery does not replenish streaming tool depth` |
| Ordered lifecycle transitions with safe fields and actual wire counts; admission/backoff consume no model/tool budget | `recovery_wire_test.exs`: `<gateway> <operation> real Req 503 recovers with identical full payload and correlated lifecycle`, `cancellation inside initial worker guard has no wire lifecycle`; `stream_recovery_wire_test.exs`: `<gateway> <mode> recovers 503 with immutable full payload and exact lifecycle` |
| Opt-in exact request/response traces, including partial/error responses; capture failure never succeeds or resends; observe before capture | `cancellation_socket_wire_test.exs`: `blocked body capture retains observed semantic evidence before public delivery`; `recovery_wire_test.exs`: `<gateway> <operation> incomplete 200 <interruption> tracing <tracing> admitted <admitted> retains exact body evidence`; `first_token_wire_test.exs`: `split-frame observation survives rejected capture without output or resend` |
| Safe Inspect, JSON, logs and lifecycle exclude credentials/payload/cause text; explicit private inspection | `provider_metadata_wire_test.exs`: `public OpenAI ordinary errors omit decorated short alphabetic prompt echoes`; `recovery_wire_test.exs`: `recognized provider code and UUID request ID echoes cannot enter public recovery metadata`, `real Req sleeper <failure> failure never enters safe errors history events or logs` |
| October 12 admission without hook: remote eligible retries; local requires admission unless acceptance no | `admission_wire_test.exs`: `<gateway> <entrypoint> no hook <scenario> preserves wire and lifecycle contract`; `no_hook_wire_test.exs`: `local event stream without admission never resends an ambiguous failure` |
| October 12 admission without decision has its own reason; no resend | `admission_wire_test.exs`: `<gateway> <entrypoint> admission <outcome> preserves terminal identity and never resends` (explicit rejection, undecided return, raise/throw/exit, worker death) |
| October 12 five documented capabilities, endpoint/date citations, all exact-attempt termination unknown | `recovery_capabilities_test.exs`: `v1 <provider> <capability> declares <value> with exact inspected evidence`, `<provider> retains atom values and unknown exact-attempt termination` |
| October 12 provider metadata: allowlisted codes, IDs cannot echo outbound secrets; provider field names | `provider_metadata_wire_test.exs`: `<gateway> <operation> <fixture> preserves safe metadata and immutable wire retries`, `<gateway> <operation> <fixture> semantic provider errors retain sensitive evidence privately` |
| October 12 all HTTP dates and complete RFC 850 50-year rollover | `retry_after_dates_wire_test.exs`: `RFC 850 December 2076 rolls back to 1976 through real Req`, `<gateway> <entrypoint> RFC 850 <label> <scenario> compares the complete 50-year cutoff through Req`, plus the form/minimum cases above |
| October 12 closed provider/operation types and typed policy/capture/length errors through public consumers | `typed_errors_wire_test.exs`: `<gateway> <entrypoint> <scenario> retains typed cause and forbids replay`, `<gateway> <object|broker_object> truncated JSON retains length rather than a parser error`, `session retains typed length failure through the real Req boundary` |
| October 12 oMLX keepalives are raw-only; no frame/usage/model changes | `stream_recovery_wire_test.exs`: `oMLX recovery ignores coalesced keepalives around real provider completion`; `omlx_keepalive_wire_test.exs`: `<entrypoint> <layout> keepalives preserve exact output metadata and progress`, `<mode> minimal keepalive cannot supply completion evidence`, `<mode> capture failure on keepalive retains raw bytes without semantic progress` |
| October 12 public-boundary evidence for partial reasoning/content/tool interruption, safe lifecycle, selection and HTTP 500/502 | `stream_recovery_wire_test.exs`, `recovery_wire_test.exs`, `typed_errors_wire_test.exs` generated Broker/session cases compare failure, progress, final history, no tool execution and no successful terminal event |

Provider capability tables and recovery migration examples are in
`guides/broker.md` and the gateway guides. These tests establish local library
behavior; local socket closure does not prove remote inference termination.

## Part 2: native reasoning decision-to-test mapping

All rows use `reasoning_wire_test.exs` and `native-reasoning-v1` through Req.

| Binding decision | Named behavioral evidence |
| --- | --- |
| Native history separate from visible/tool content, Ollama `thinking`, oMLX `reasoning_content`; exact six efforts without conflation; omitted effort unknown | `<gateway> <boundary> <operation> sends exact <effort> control and native history`; `<gateway> <operation> retention leaves absent native reasoning omitted` |
| Explicit profiles, no name guessing, supported efforts/history; Qwen3.8 disabled/low/medium/xhigh | `<gateway> <boundary> <operation> validates caller-selected profile before HTTP`; `<gateway> Qwen3.8 accepts exact <effort> on an unrelated model name`; `invalid reasoning configuration fails before HTTP` |
| Opt-in Broker retention, ordinary/streamed completed turns only, no fabricated history after failure/cancellation | `<gateway> <operation> tool continuation retains native reasoning only with preserve=<boolean>`; `<gateway> <failure> stream never executes tools or fabricates a continuation`; `<gateway> incomplete ordinary native turn cannot execute tools or retain history` |
| oMLX `chat_template_kwargs.preserve_thinking`, including unset effort | `completed native reasoning and exact tool identity survive a real Req continuation`; `<gateway> <operation> requests native retention without inventing effort` |
| Structured controls equal ordinary/stream controls; reasoning outside JSON | effort matrix above and `<gateway> structured response keeps native reasoning outside the JSON object` |
| OpenAI explicitly rejects new extensions; legacy behavior preserved | `OpenAI <operation> explicitly rejects new controls and native history before HTTP`; `OpenAI preserves legacy <effort> effort and history through Req` |
| Public ChatSession forwarding and visible history | `ChatSession ordinary and stream paths forward exact controls and validate profiles`; `legacy ChatSession stores visible content separately from native stream reasoning` |

## Part 3: metadata and request-fidelity decision-to-test mapping

| Binding decision | Named behavioral evidence |
| --- | --- |
| Optional gateway callback, legacy not-advertised fallback; positive capacity with provenance, optional model num_ctx; errors distinct from missing | `context_window_wire_test.exs`: `context-window-v1 <boundary> <provider> <row> exact wire and result`; `model_context_window_test.exs`: `legacy gateway without optional callback returns not advertised without dispatch` |
| Authenticated configured oMLX GET exact ID; Ollama POST architecture suffix, parameters and 404; invalid/malformed shapes and transport errors | wire fixture matrix above; `<gateway> <boundary> transport failure retains cause`; rows include missing entries/fields, nonpositive/noninteger capacities, string-wrapped JSON and multiple architecture prefixes |
| OpenAI exact registry only, no heuristic guess/HTTP, old capability fallback intact | `context-window-v1 registry <model> performs no HTTP`; `model_context_window_test.exs`: `registry metadata does not alter capability or pattern fallback`, `registry entries without a positive known capacity never invent a window` |
| Pure effective capacity: caller then model num_ctx, clamp above/below/equal, no capacity remains unknown; discovery no request/session side effects | `context-window-v1 effective precedence and clamping <index>`; `Ollama discovery separates advertised and effective windows through production Req`; `<gateway> discovery leaves subsequent <operation> request unchanged`; configured lookup before/after discovery cases |
| Monotonic dispatch start after preparation/capture; pre-dispatch rejection/cancellation gives no traffic/timing; response observed before capture | `first_token_wire_test.exs`: `<provider> <route> blocked request capture <outcome> excludes pre-dispatch time and evidence`; `split-frame observation survives rejected capture without output or resend` |
| First token only; thinking > content > nonempty tool arguments; empty/name/keepalive ignored; empty/error terminals and provider metrics retained | `<provider> <route> <row> without recovery measures the production dispatch`; split-capture matrix; `<provider> recovery <mode> HTTP rejection has duration without a first token`; disconnect/error cases and Ollama final frame without newline cases |
| One clock across admitted retries; each tool continuation resets; terminal evidence on legacy/events/Broker/ChatSession | `<provider> <route> admitted retry spans one dispatch clock and repeats exact wire request`; `tool continuation starts a fresh clock and executes once`; `<provider> default session forwards timing and finalizes successful history` |
| Optional temperature/num_ctx/max_tokens, no invented fallback; removed public num_predict; set controls once with native names; no client-only fields | `immutable_request_wire_test.exs`: `fidelity-v1 <gateway> <boundary> <operation> <row> exact body and admitted replay`; seven fixture rows, default and individually set controls including zero; same suites across continuations and legacy APIs |
| OpenAI fixed temperature adaptation and warning/drop of unsupported effort, nil-safe registry | fidelity matrix plus `gateways/openai_model_registry_test.exs`; `context_window_wire_test.exs` configured registry lookup preservation |
| ChatSession forwards per-send controls, zero temperature, no implicit context/default; tool requests/retries identical | `fidelity-v1 <gateway> <boundary> legacy tool continuation <row> exact bodies and admitted replay` (Broker/session); context discovery no-side-effects cases |
| Required-provider exception | oMLX omits unset max_tokens, verified by the fidelity matrix; Anthropic is not a maintained Elixir adapter, so its required-limit fallback does not apply |

Nonstream request duration is optional in the contract. Capacity discovery does
not change trimming or guess server residency. Guides for Broker, ChatSession,
streaming, oMLX and OpenAI registry describe these public operations and migration.

Additional concrete assertion inputs for the profile and discovery decisions:

| Named case | Input → asserted public output/error |
| --- | --- |
| `reasoning_wire_test.exs`: `<gateway> <boundary> <operation> validates caller-selected profile before HTTP` | Qwen3.8 profile with enabled/high → `{:unsupported_reasoning_effort, "qwen3.8", effort}`; a boolean profile without native-history support plus preserve_reasoning=true → `{:unsupported_reasoning_history, "boolean"}`. Ordinary APIs return error tuples, stream APIs yield the corresponding errors, and adapter requests remain empty. |
| `reasoning_wire_test.exs`: `<gateway> Qwen3.8 accepts exact <effort> on an unrelated model name` | nil/disabled/low/medium/xhigh on a caller-selected Qwen3.8 profile → exact native controls on the unrelated model name, proving no heuristic name selection. |
| `context_window_wire_test.exs`: `context-window-v1 <boundary> <provider> <row> exact wire and result`; `Ollama discovery separates advertised and effective windows through production Req` | qwen4_exp.context_length=262144 and parameters num_ctx=32768 → advertised capacity 262144 with provider provenance, model_num_ctx=32768, effective capacity 32768; explicit caller context overrides and clamps. Contract malformed/missing/nonpositive rows assert their distinct errors versus not advertised. |
| `model_context_window_test.exs`: `registry entries without a positive known capacity never invent a window`; `registry metadata does not alter capability or pattern fallback` | nil capacity → `{:ok, nil}`; zero/negative/float/string/boolean → `{:error, :invalid_response}`. Unknown capacities do not change pre-existing capability/token-parameter fallbacks. |

## Parts 4–5 applicability

Elixir has no Kotlin iOS targets, Python Anthropic adapter or Rust numeric casts.
Zero temperature is applicable and remains asserted in the request-fidelity
matrix through ChatSession, continuations and admitted retries.

## Offline verification boundary

All current cases use in-process boundary doubles. `ScriptedTransport` implements
Req's documented adapter interface; the public gateway, Broker and ChatSession
APIs retain production ReqClient preparation, dispatch, observation and cleanup.
HTTP-shaped fixture strings are decoded into responses in memory. Request
transcripts render the method, path, prepared headers and exact body observed by
the adapter; they do not claim protocol framing, generated Host/Content-Length,
TCP peer state or remote termination. Cleanup is established by adapter cancel
callbacks and monitored consumer exit. Tests inject native transport exceptions
for closed/refused/timeout outcomes; they never wait for a transport timer.

The server-only idle/absolute timer and Finch-versus-receive timer-race cases were
removed. Public timeout classification, received evidence, privacy, single-send
behavior and cancellation remain in `recovery_wire_test.exs`'s **stalled body
tracing ... preserves timeout without resend**, **incomplete 200 ... retains
exact body evidence**, and **Req receive timeout preserves uncertainty without
resend** matrices. The replacement **zero <mode> timeout distinguishes queued data from an expired
absolute deadline** cases in `req_client_test.exs` use `recv_timeout: 0`: idle
consumes queued `partial` then yields `:timeout`; absolute immediately yields
`:timeout`. Both close exactly one response with no resend or elapsed-time check.
The additional **absolute deadline expires after explicit clock advance for HTTP
200/503** cases consume one body fragment, advance the injected clock by the
1000ms budget and assert exact timeout events, received error-body evidence,
cleanup and one request. No transport timer or elapsed-time threshold is used.
The readiness source and fresh Hex consumers also run CurrentDatetime's exact
UTC/Unix assertions and explicit second advance, TracerSystem's exact timestamp
assertions across a 1250ms advance, DateResolver's missing/invalid
reference fallback with an explicit day advance, and dispatcher tests that send
`:process_events` directly rather than waiting for its periodic timer.

Concurrent response cleanup remains in `req_client_test.exs`'s
**closing one stream leaves another stream at the same origin cancellable**.

The TypeScript v1/v2 source identities remain provenance in
`stream_first_token_v1.json`; their socket-based source copies and hash-only
reference test are removed. Behavioral first-token cases remain executable.
The shared contract selects the additional **prepared dispatch precedes
observation and rejected capture retains timing without delivery** probe in
`offline_transport_test.exs`. An empty response delta rejects observed-content
assertions; a content delta passes with 25ms first-token, 80ms duration,
`:capture_failed`, observed=true, delivered=false, one request and cleanup.

See [the executable decision map](test/contracts/DECISIONS.md) for concrete inputs,
expected public outputs/errors and named assertions for each binding decision.
The current local recovery text is synchronized with the authoritative root
contract, read-only from the sibling checkout. No sibling files were edited.

Verification results and exact worktree/contract identities are recorded in
[verification evidence](audit/offline-verification.md).
