# Completion recovery conformance

Current completion recovery is verified offline through public APIs, using the
same executable cases for source and fresh extracted Hex-payload consumers.
The local normative contract is synchronized with the authoritative root text.
Git retains superseded implementation and run records.

### Normative requirement map

All test paths in this table are under `test/mojentic/llm/`. The wire modules
exercise production ReqClient against the in-process Req adapter, through
OpenAI, Ollama and oMLX public completion APIs; they do not call live inference.
The assessment distinguishes source review, executed assertions and external
obligations rather than inferring behavior from test counts.

The concrete adapter entrypoints are `complete/4`, `complete_object/4`,
`complete_stream/4` and `complete_stream_events/3` in
`lib/mojentic/llm/gateways/{openai,ollama,omlx}.ex`. Forwarding assertions cover
`Broker.generate/4`, `generate_response/4`, `generate_object/4`,
`generate_stream/4`, `generate_stream_events/3` and `ChatSession.send/3`,
`send_stream/3`, `finalize_stream/1` in their corresponding LLM modules.

| Requirement | Actual implementation and independently checked assertions |
| --- | --- |
| Completion-only ownership; no agent restart | `CompletionRequest.run/8` and `StreamRecovery.stream/8` own one immutable request. `Broker` and `ChatSession` propagate recovery configuration; retries do not re-enter the broker loop. Realtime, embeddings and model management remain outside this contract. |
| Structured failure and bounded history | `CompletionError` defines category, provider, operation, numeric status, validated code/ID, Retry-After, phase, acceptance, observed/delivered progress, eligibility, permission, identities and private cause/evidence. `Recovery.loop/5` appends dispatched failures up to maximum attempts. `recovery_wire_test.exs` persistent-504 cases assert exact final error and ordered history, not only failure existence. |
| Default compatibility and opt-in behavior | `CompletionConfig.recovery == nil` selects legacy adapter paths; enabled requests select `CompletionRequest`/`StreamRecovery`. `Recovery` defaults to one attempt. Disabled cases in `stream_recovery_wire_test.exs`, gateway tests and the full suite characterize legacy behavior. This does not promise disabled reasoning parity or change ordinary finish handling. |
| Explicit policy and safe eligibility | `Recovery.valid_options?/1`, `eligible?/2`, `safe_stream_failure?/1` separate caller selections from resend permission. Malformed/protocol/capture failures cannot become successful retries. `recovery_wire_test.exs` permanent/decoding cases and `permanent_http_wire_test.exs` assert no blind resend under explicit category/status selection. |
| Permanent status survives truncated body | `CompletionRequest.classify/2` retains HTTP precedence and `Recovery.eligible?/2` vetoes 400/401/403 regardless of caller selections. `permanent_http_wire_test.exs` covers complete, closed and timeout bodies with tracing on/off across all four APIs; selected transient 503 is the positive control. Follow-up cases in `stream_recovery_wire_test.exs` retain completed tool history without replay. |
| Exact attempt limits and hidden retry removal | Recovery-enabled ordinary Req sets `retry: false`; streaming ReqClient does likewise. 503 recovery and persistent-504 wire cases assert exact transport-observed request count, distinct attempt IDs, one logical ID and complete lifecycle/history. Admission waits have no wire identity of their own. |
| Exponential jitter and Retry-After | `Recovery.delay/2`, retry-after parsing and injected clock/jitter/sleeper implement bounded full jitter and provider minimum delays. `recovery_wire_test.exs` tests seconds/date/invalid/past headers, delay/budget refusal, first-failure monotonic budget, doubling/saturation and overflow. Refusal retains original HTTP failure. |
| Recovery limits never time out active generation | `Recovery.guard_send/2` checks before dispatch, admission and delay. The deadline/budget bounds recovery only. Both recovery wire modules assert active generation may finish after the deadline and prohibit sends at the exact deadline. There are no server-only gate timeout allowances. |
| Asynchronous admission and local ambiguity | `Recovery.admission/2` supplies safe failure, previous attempt/logical identity, next attempt and progress, with explicit allow/reject/pending replies. Local ambiguous acceptance requires admission; timeout does not prove remote termination. Wire tests hold pending callbacks, assert no second request, resolve allow/reject and cancel blocked workers. |
| Cancellation received evidence | `ReqClient`, `ReceivedEvidence` and `WireTrace` record received headers/body before external capture. `Recovery.await_request/8` and `CompletionRequest.cancelled/7` retain that evidence and native cause. `cancellation_socket_wire_test.exs` and the headers/partial/terminal and post-worker matrices assert exact bytes, HTTP 200/401, correlated identities/history, zero undelivered output and correlated adapter response cleanup. |
| Paused consumers and terminal precedence | `StreamRecovery.authorize_success/2` requires consumer demand after final capture/cleanup. `cancellation_socket_wire_test.exs` cancels the observer-reported owner while the consumer stays paused, requires failed/cancelled lifecycle and adapter cleanup before resumption, then rejects completion/tool execution and preserves session history. Sending only to a paused enumerator's mailbox cannot provide prompt forwarding. |
| Observed versus delivered semantics | `ReceivedEvidence.observe/2` and stream snapshots distinguish raw bytes, reasoning, content, fragments and completed calls from acknowledged delivery. Keepalive-only cases may recover; semantic partial cases interrupt without replay. Same-chunk parser/observation failures retain observed progress without falsely marking delivery. |
| Capture failure retains progress and cannot resend | `CompletionRequest.retain_stream_capture/3` merges received evidence with observed/delivered snapshots. `stream_recovery_wire_test.exs` asserts rejected terminal capture retains exact body/content observation without completion or delivery. Callback return/raise/throw/exit and broker/session tests require terminal `capture_failed`, no resend and no tool execution. |
| Immutable semantic payload and native controls | Adapters encode body and freeze endpoint/headers before recovery. `immutable_request_wire_test.exs` independently specifies expected payloads, compares disabled wire and admitted retries byte-for-byte, mutates image input after dispatch, and asserts native reasoning/tool/schema/sampling controls and prior session conversation. Legacy-adaptation freeze is checked in `recovery_wire_test.exs`. |
| Privacy and inspectable original cause | `CompletionError.safe_metadata/1`, custom Inspect/Jason and safe broker/tracer logging omit private cause/evidence. Explicit `cause/1` and `received_evidence/1` retain sensitive data. Sentinel tests in both recovery wire modules cover credentials, content, tool arguments, provider-code/request-ID echoes and callback/sleeper errors. Explicit raw capture is sensitive and caller-owned. |
| Lifecycle ordering and exact identities | `immutable_request_wire_test.exs` compares every event's complete logical ID, attempt ID and wire number against actual trace requests. Retry transition names the failed attempt and actual next wire number. In the lifecycle verifier, exactly one response-end and attempt terminal must exist, with integer positions, before ordering is compared. No nil-index ordering can establish success. |
| Independently rejecting identity assertions | The transport-observed negative matrix at `immutable_request_wire_test.exs` removes/corrupts/masks each identity independently and removes response-end/failure/success. Additional transition loops mutate every non-start transition. Each altered observation must raise `ExUnit.AssertionError`; original observations must pass. These mutate verifier input, not production output. |
| Telemetry ordering and rejected terminals | `StreamRecovery.ollama_frame/2` and `ollama_telemetry/2` emit validated progress/metrics before accepted semantics or terminal rejection. Tests at `stream_recovery_wire_test.exs` assert exact metadata, paused cancellation, capture failure, preserved prior semantics, no fabricated metadata and no completed rejected tools. OpenAI/oMLX cannot invent Ollama metrics. |
| Completed tools execute once; depth retained | Broker tool execution follows accepted completion. `immutable_request_wire_test.exs`, `recovery_wire_test.exs` and `stream_recovery_wire_test.exs` require one execution, exact tool-result follow-up history, immutable admitted resend and unchanged tool-depth budget. Interrupted/capture-failed streams cannot execute completed-but-undelivered tools. |
| Capabilities and migration | `Recovery.capabilities/1` and [streaming guide](guides/streaming.md) expose local cancellation supported, remote cancellation/status/idempotency unsupported and exact remote termination unknown for all three adapters. Migration documents opt-in config, admission, error conversion and sensitive trace ownership. Custom HTTP implementations need both observers; guarantees here apply to ReqClient. |
| Gates, audit policy and retained evidence | Final gate results and executable identities are recorded in audit/offline-verification.md. Runtime pins, the coverage floor and existing security configuration are unchanged. The local advisory snapshot is scanned without filtering; findings and tool limits are reported in the audit. |
| Cross-port provenance and external limits | TypeScript contract identities are provenance. The October 17 library policy requires source public consumers and a fresh local Hex consumer, with dependents verifying upon adopting a published version. No external port execution or running service verification is claimed; model efficacy remains outside this assessment. |


## Executable cases and results

[CONFORMANCE-3.0.0.md](CONFORMANCE-3.0.0.md) names recovery, reasoning, discovery,
timing and fidelity cases. The [decision map](test/contracts/DECISIONS.md) specifies
inputs and expected public outputs/errors. [Verification evidence](audit/offline-verification.md)
records exact source and packaged-consumer identities, executable hashes and gates.

The Req adapter supplies responses and native exceptions, records prepared request
bytes and observes cancellation. It does not mock Mojentic internals. Resource
closure proves local cleanup, never remote termination. Socket timer races and
protocol framing tests were removed; classification, evidence retention,
admission, cancellation, immutable replay and terminal behavior remain asserted.

## Retry-worker cancellation synchronization

`recovery_wire_test.exs`: `<gateway> <operation> cancellation inside retry worker
guard retains only dispatched failure` covers OpenAI, Ollama and oMLX ordinary
and structured APIs. The injected clock blocks a non-caller only after the
public `:retry_started` observation. The worker acknowledges the installed
monitor and remains blocked before cancellation reaches the public request
owner. The monitor must report `:killed`; `:noproc` fails. The adapter records
exactly the original request and no resend. The returned error retains HTTP 503,
request ID, Retry-After, original cause, logical/attempt identities and one
history entry; the ordered lifecycle ends in `:cancelled`.

The complete binding parts 1–3 map remains in
[3.0.0 conformance](CONFORMANCE-3.0.0.md) and the
[named decision assertions](test/contracts/DECISIONS.md), including parts 4–5
applicability. These executable names, rather than historical line positions,
identify the evidence on the final tree.

## Binding recovery assertions on the current tree

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


Parts 2–3 named assertions and applicability are maintained in the linked
3.0.0 conformance map; the shared readiness manifest executes those same files.
