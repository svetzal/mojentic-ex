# Request fidelity: local conformance and coordination record

This is current 3.0.0 evidence for RELEASE-3.0.0 part 3 and
MODEL-METADATA-2026-10 sections 3–3.6, source SHA-256
`d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c`.
The initiative brief was read and verified as
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
Context discovery and first-token timing are covered by the aggregate contract.

## Characterized public boundaries

`CompletionConfig.new/1` and struct literals feed `Gateway.complete/4`,
`complete_object/4`, `complete_stream/4` and `complete_stream_events/3`.
`Broker.generate/4`, `generate_object/4`, `generate_stream/4` and
`generate_stream_events/3` forward the same configuration. ChatSession supports
ordinary and legacy streaming sends; it has no structured/event-stream send API.

Previously config defaults were temperature 1.0, context 32,768 and output
16,384. OpenAI invented a fallback output limit even for unset config; Ollama
preferred a separate `num_predict`; oMLX sent temperature unconditionally.
ChatSession injected temperature 1.0 and dropped per-send sampling and limits.
Its 32,768 local history-trimming budget is a separate decision and stays intact.
Broker already forwards config temperature to tracing; nil remains nil and is
omitted from the printable temperature summary. Registry numeric comparisons
now accept nil as a valid request for omission.

All three adapters omit unset sampling/context/output fields. Explicit zero
temperature survives. OpenAI still rewrites an explicit unsupported fixed
model temperature to 1.0, warns when dropping effort on non-reasoning models,
and omits unsupported top_k/context settings. Ollama alone uses num_ctx and
maps the sole max_tokens field to options.num_predict. oMLX uses max_tokens
only when set; there is no required fallback. Native reasoning is unchanged.

## Executable contract

`request-fidelity-v1` consists of:

- `test/contracts/request_fidelity_v1.json`: versioned named inputs, response
  fixtures, a retryable provider error and native tool-call fixture.
- `test/mojentic/llm/immutable_request_wire_test.exs`: exact semantic bodies and
  executable behavior, shared by direct adapter and Broker/ChatSession cases.
- `test/mojentic/llm/gateways/openai_model_registry_test.exs`: nil-safe capability
  checks alongside existing fixed-temperature decisions.
- `test/support/scripted_transport.ex` and `counting_tool.ex`: in-process Req
  adapter and tool outcome. Completion responses and the next-turn tool call
  come from the contract artifact, rather than independent mocks.

Run `scripts/verify-request-fidelity-contract`. It prints the tested Git base,
production source hashes and executable artifact hashes, then verifies both
local sides in one command. `mix test` and `mix test --cover` include the same
executable cases in the required project/CI gates. The pinned runtime remains
Elixir 1.18.5 and OTP 28.5.0.7. There are no dependency/runtime/version changes.

| Requirement | Named executable cases |
| --- | --- |
| Unset parameters and each explicit field | `fidelity-v1 <gateway> <gateway/broker> <complete/object/legacy/events> <unset/zero-temperature/context-only/output-only/sampling/all/explicit-nil> exact body and admitted replay` compares the entire decoded body and byte-identical original/retried requests |
| Provider output-limit names | Same cases; OpenAI o3 adaptation matrix checks max_completion_tokens; all other models use max_tokens, and Ollama uses options.num_predict |
| oMLX no required fallback | Same unset/explicit-nil matrices; no temperature or output limit present |
| Nil-safe reasoning-model registry | `fidelity-v1 OpenAI <operation> unset reasoning limit and temperature stay absent`; `an unset temperature is valid for unrestricted, fixed and unknown models` |
| Fixed-temperature adaptation and dropped effort | Existing `OpenAI o3 <operation> preserves supported <effort> reasoning controls and model adaptation` plus full gpt-4o immutable-body matrix; warning capture remains in the full suite |
| Session controls, zero and nil overrides | `fidelity-v1 <gateway> session <complete/legacy> <case> preserves per-send values`; independent max_context does not reach the request |
| Session defaults and admitted retries | Existing `<gateway> ChatSession <operation> freezes full prior history for its current turn`; entire default body and immutable retry bytes |
| Broker tracing | `fidelity-v1 <gateway> Broker tracing retains unset and zero caller temperature`; trace values, summaries and exact wire bodies |
| Tool continuation with default settings | `<gateway> unset parameters survive a tool continuation and admitted retry through production Req`; exactly one tool outcome, omitted defaults, unchanged continuation replay bytes |
| Legacy streaming tool continuations and session finalization | `fidelity-v1 <gateway> <broker/session> legacy tool continuation <unset/zero-temperature/context-only/output-only/sampling/all/explicit-nil> exact bodies and admitted replay` (tag `legacy_continuation_fidelity`); 42 cases compare independently specified whole initial and continuation documents, including system/user/assistant/tool messages, native identifiers, arguments and result, with no deleted or masked fields. They assert one tool execution and admission, a contract-defined 503, byte-identical continuation replay, final streamed answer and successful finalized session history. Explicit nil and zero override a non-nil session temperature; `max_context` does not reach the wire. |
| Rich history, explicit settings, tools and retries | Existing `<gateway> broker admitted follow-up freezes complete history and mutable image without tool replay`; entire initial and follow-up bodies, image mutation after admission, byte equality, attempt/failure identities and trace chronology |
| Errors and terminal streams | 503 contract response is admitted and replayed; existing recovery/typed-error/native-reasoning suites remain in full gates, including length, cancellation, no semantic replay and invalid-policy zero dispatch |

Recovery-disabled Ollama's legacy stream can re-enumerate its underlying Req
stream and issue repeated identical requests. This existing behavior is outside
this correction. The contract checks every observed decoded body and compares
them to recovery-enabled replay; it does not claim a request-count guarantee for
that legacy implementation. Recovery-enabled streams retain terminal semantics.

## Current verification

The same cases run from source and from a freshly extracted local Hex payload
through `ex-readiness-v1`. Dependencies are supplied locally without registry
access. See [current conformance](CONFORMANCE-3.0.0.md), the
[decision map](test/contracts/DECISIONS.md) and [verification evidence](audit/offline-verification.md)
for named behavioral assertions, tested identities and executable hashes. No
running service boundary or sibling repository is changed.
