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
| Cancellation received evidence | `ReqClient`, `ReceivedEvidence` and `WireTrace` record received headers/body before external capture. `Recovery.await_request/8` and `CompletionRequest.cancelled/7` retain that evidence and native cause. `cancellation_socket_wire_test.exs:27` and the headers/partial/terminal and post-worker matrices assert exact bytes, HTTP 200/401, correlated identities/history, zero undelivered output and actual peer socket closure. |
| Paused consumers and terminal precedence | `StreamRecovery.authorize_success/2` requires consumer demand after final capture/cleanup. `cancellation_socket_wire_test.exs:693` cancels the observer-reported owner while the consumer stays paused, requires failed/cancelled lifecycle and socket closure before resumption, then rejects completion/tool execution and preserves session history. Sending only to a paused enumerator's mailbox cannot provide prompt forwarding. |
| Observed versus delivered semantics | `ReceivedEvidence.observe/2` and stream snapshots distinguish raw bytes, reasoning, content, fragments and completed calls from acknowledged delivery. Keepalive-only cases may recover; semantic partial cases interrupt without replay. Same-chunk parser/observation failures retain observed progress without falsely marking delivery. |
| Capture failure retains progress and cannot resend | `CompletionRequest.retain_stream_capture/3` merges received evidence with observed/delivered snapshots. `stream_recovery_wire_test.exs:217` asserts rejected terminal capture retains exact body/content observation without completion or delivery. Callback return/raise/throw/exit and broker/session tests require terminal `capture_failed`, no resend and no tool execution. |
| Immutable semantic payload and native controls | Adapters encode body and freeze endpoint/headers before recovery. `immutable_request_wire_test.exs:34,119,154,191` independently specifies expected payloads, compares disabled wire and admitted retries byte-for-byte, mutates image input after dispatch, and asserts native reasoning/tool/schema/sampling controls and prior session conversation. Legacy-adaptation freeze is checked in `recovery_wire_test.exs`. |
| Privacy and inspectable original cause | `CompletionError.safe_metadata/1`, custom Inspect/Jason and safe broker/tracer logging omit private cause/evidence. Explicit `cause/1` and `received_evidence/1` retain sensitive data. Sentinel tests in both recovery wire modules cover credentials, content, tool arguments, provider-code/request-ID echoes and callback/sleeper errors. Explicit raw capture is sensitive and caller-owned. |
| Lifecycle ordering and exact identities | `immutable_request_wire_test.exs:751` compares every event's complete logical ID, attempt ID and wire number against actual trace requests. Retry transition names the failed attempt and actual next wire number. At `:794`, exactly one response-end and attempt terminal must exist, with integer positions, before ordering is compared. No nil-index ordering can establish success. |
| Independently rejecting identity assertions | The transport-observed negative matrix at `immutable_request_wire_test.exs:263` removes/corrupts/masks each identity independently and removes response-end/failure/success. Additional loops at `:711` mutate every non-start transition. Each altered observation must raise `ExUnit.AssertionError`; original observations must pass. These mutate verifier input, not production output. |
| Telemetry ordering and rejected terminals | `StreamRecovery.ollama_frame/2` and `ollama_telemetry/2` emit validated progress/metrics before accepted semantics or terminal rejection. Tests at `stream_recovery_wire_test.exs:29,185,217,342,404,430` assert exact metadata, paused cancellation, capture failure, preserved prior semantics, no fabricated metadata and no completed rejected tools. OpenAI/oMLX cannot invent Ollama metrics. |
| Completed tools execute once; depth retained | Broker tool execution follows accepted completion. `immutable_request_wire_test.exs:34`, `recovery_wire_test.exs:2232,2323` and `stream_recovery_wire_test.exs:307,1296,1476,1589` require one execution, exact tool-result follow-up history, immutable admitted resend and unchanged tool-depth budget. Interrupted/capture-failed streams cannot execute completed-but-undelivered tools. |
| Capabilities and migration | `Recovery.capabilities/1` and [streaming guide](guides/streaming.md) expose local cancellation supported, remote cancellation/status/idempotency unsupported and exact remote termination unknown for all three adapters. Migration documents opt-in config, admission, error conversion and sensitive trace ownership. Custom HTTP implementations need both observers; guarantees here apply to ReqClient. |
| Gates, audit policy and retained evidence | Fresh commands, exits, complete capture hashes, source hashes and review are retained outside the disposable checkout as described below. Runtime pins, coverage floor, exclusions, gate timeout, socket assertions and suppressions are unchanged. Unfiltered findings remain visible and informational under the October 11 owner policy; configured success is not an unfiltered clean audit. |
| Cross-port/harness obligations | Exact Rust source comparison is recorded below. Five-port acceptance, harness revision/lock pinning, fresh registered experiment, durable trace persistence and model efficacy remain external obligations. This worker neither edits nor certifies the harness/parity matrix and does not restart any stopped experiment. |


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
