# Request fidelity: local conformance and coordination record

This is partial 3.0.0 evidence for RELEASE-3.0.0 part 3 and
MODEL-METADATA-2026-10 sections 3–3.6, source SHA-256
`a085da1c0d110f9d587a24ace6ac2854b653e1ac28905b3829d94d665b2c906e`.
The initiative brief was read and verified as
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
Context discovery and first-token timing remain subsequent objectives.

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
- `test/support/scripted_completion_server.ex` and `counting_tool.ex`: real TCP
  boundary and tool outcome. Completion responses and the next-turn tool call
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

## Versions and external verification gap

3.0.0 intentionally changes the 2.1.0 default-request contract. The migration
profile explicitly restores temperature 1.0, num_ctx 32,768 and max_tokens
16,384; the removed num_predict config key must become max_tokens. There is no
claim that the two default configurations are behaviorally compatible. Provider
wire formats remain chat completions (OpenAI/oMLX) and /api/chat (Ollama).

The local adapter/provider side and Broker/ChatSession consumer side execute
this same versioned set through production Req against contract-derived scripted
responses. This proves the declared local request and consumer behavior, not a
live provider's compliance or a cross-repository consumer's agreement. External
OpenAI, Ollama and oMLX implementations and bedrock/bedrock-workshop have not
verified this set in this execution. Their source identities, supported server
versions, commands and results are unavailable. Paired external verification
is unfinished and must be assigned as separate authorized initiative work using
this same artifact and executable semantics. No other repository was edited.
No publication, Git finalization or coordinated-release readiness is claimed.

## Cycle 10: legacy streaming continuation verification

The base for both local sides is
`ff479d92067b6ffbd99d3cd5533f96e13ebc09b0`, plus the uncommitted test changes
identified below. This run closes only cycle 9's local legacy-stream verification
gap. No production fidelity defect was demonstrated, so Broker's recursive
configuration forwarding and ChatSession's forwarding/finalization remain intact.
The existing verifier already includes the extended executable file, so its
entrypoint and the normative JSON contract need no change.

Streaming tool responses are derived from `request_fidelity_v1.json`'s
`tool_call`; final streamed responses and the admitted retry's 503 come from
that same artifact. The Ollama frame uses native object arguments, while
OpenAI/oMLX use an indexed SSE tool delta. Expected documents are specified
independently of production adapters and the tool descriptor implementation.
Ollama's outgoing messages omit call IDs by its established native mapping;
OpenAI/oMLX retain the exact `next-id` in both call and result messages. No
message or identifier is removed from captured requests during comparison.

Before expanding to 42 cases, the hardest probe exercised OpenAI ChatSession,
all explicit caller controls (including zero temperature), a streamed tool call,
an admitted continuation 503 and a final answer through production Req. A
temporary source mutation cleared sampling/context/output settings only in
Broker's recursive continuation. The test rejected the resulting entire
continuation body (exit 2): temperature 0, max_tokens 73 and top_p 0.8 were lost.
Restoring the existing config forwarding made the same probe pass (exit 0).
The mutation is absent from the review snapshot. This proves the new assertions
reject a concrete wire fidelity regression; it does not claim a pre-existing
production bug was fixed.

## Tested source identities

Contract version: `request-fidelity-v1`. Its normative source SHA-256 remains
`a085da1c0d110f9d587a24ace6ac2854b653e1ac28905b3829d94d665b2c906e`.
The JSON artifact is unchanged; its hash and the executable/production source
hashes identify the tested working-tree snapshot in addition to the base commit.

| Artifact | SHA-256 |
| --- | --- |
| `test/contracts/request_fidelity_v1.json` | `6f02088311f50707b9c12154d888f844928c23d359043cb2e5d5654bf7e5eaea` |
| `test/mojentic/llm/immutable_request_wire_test.exs` | `30172621c6af8c4ff4059077dbc87c6533d78b19a036d6687aa040e3efbf94dc` |
| `test/mojentic/llm/gateways/openai_model_registry_test.exs` | `467a13033dd91a07f53ec825d49ce48f372da2fa8a187021e3de9c0f21cab192` |
| `test/support/scripted_completion_server.ex` | `d03a3cf93eb25350bd8bf2387e70fbf7786e86e663809f55dfd7180f6e782e07` |
| `test/support/counting_tool.ex` | `87eed78d78cd23be5082bfe504af1322127019f064f69b9179c4428c923fe194` |
| `scripts/verify-request-fidelity-contract` | `4d2bc2c2496b574fba9c6e551b01669ebf388d724ef2666553947d1c4b917613` |
| `lib/mojentic/llm/completion_config.ex` | `ce6d72ff11b1a500f5f9634a2d6853b382fb957b0218a90f9ebee5733431b80d` |
| `lib/mojentic/llm/chat_session.ex` | `b6794fadd69b56b7796966573fd9221630bb3bda38329e2499456a22e5ba33ab` |
| `lib/mojentic/llm/broker.ex` | `a19287109d3dc9d3c3f4fdd549bf1b4c8f32edefbdb145858da22ed74ed7f5b8` |
| `lib/mojentic/llm/gateways/openai.ex` | `259c7a5242e8b778fbe592e4c437052f2525873681b6c223d4a8653584e4bcdf` |
| `lib/mojentic/llm/gateways/openai_model_registry.ex` | `461cad7b2ee9ba130aa56b14f9165635432ae58512912bf39b5b40e3903825df` |
| `lib/mojentic/llm/gateways/ollama.ex` | `8ac900a6090b9729a2a9d36e357c67d1221f4aa51a961bbc08d461dce00aadaa` |
| `lib/mojentic/llm/gateways/omlx.ex` | `d3f671eec03d7b91d71dcd75ca9b03f1e2f05bcfac594ed5d340ed86fe630dc7` |
| `lib/mojentic/tracer/tracer_events.ex` | `7dd22297873d250c5933bc48bdfc9c4d8657c1296f84f858f08841c8ddb5f0f2` |
| `mix.lock` | `1280e3fdcc50846677f8d5bca6fa9bfa71a140472c90b6627f9fd78db65cfdb3` |

## Verification results

All commands ran in this execution worktree through Foundry capture and the
unchanged pinned runtime (`scripts/recovery-mix`, Elixir 1.18.5 / OTP 28.5.0.7).
The initiative brief hash was verified before mutation. Dependencies were
restored from the existing lockfile; no dependencies or runtime pins changed.

| Verification side | Tested source | Command | Result |
| --- | --- | --- | --- |
| Maintained OpenAI/Ollama/oMLX adapters (local provider side) | Base `ff479d92067b6ffbd99d3cd5533f96e13ebc09b0` plus snapshot above | `scripts/verify-request-fidelity-contract` | Exit 0; 390 tests, zero failures |
| Broker/ChatSession (local consumer side) | Same base and snapshot; same contract identity | Same `scripts/verify-request-fidelity-contract` | Exit 0; same 390 tests include all 42 added streaming continuation cases |
| External OpenAI/Ollama/oMLX implementations and bedrock/bedrock-workshop | Missing counterpart commits, server versions and artifact verification identities | Counterpart verification commands and results unavailable | Not run; external agreement remains unverified and requires separate authorized coordination using this same `request-fidelity-v1` set and source hash |

Local scripted provider responses establish local conformance only. They do not
establish external agreement or satisfy the outstanding counterpart verification.
No coordinated release readiness is claimed.

| Gate / applicable check | Result |
| --- | --- |
| `scripts/recovery-mix format --check-formatted` | Exit 0 |
| `scripts/recovery-mix compile --warnings-as-errors` | Exit 0 |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | Exit 0 |
| `scripts/recovery-mix test --cover` | Exit 0; 22 doctests, 5,040 tests, zero failures; 19 excluded integration tests; 90.63% coverage (80% threshold) |
| `scripts/recovery-mix credo --strict` | Exit 0; zero issues |
| `scripts/recovery-mix dialyzer` | Exit 0; zero errors, skipped errors or unnecessary skips |
| `scripts/recovery-mix deps.audit` | Exit 0; no vulnerabilities |
| `scripts/recovery-mix hex.audit` | Exit 0; no retired or security-advisory packages |
| `scripts/recovery-mix sobelow --config` | Exit 0; existing configuration unchanged |
| `scripts/recovery-mix docs` | Exit 0 |
| `scripts/recovery-mix hex.outdated --all` | Exit 1; available updates, informational only; no dependency changes under this correction's hold |

The docs build retains existing unresolved links to `../RELEASE-3.0.0.md`,
`LICENSE` and `deps/igniter/usage-rules.md` in isolated documentation inputs.
No warning suppression or unrelated documentation/dependency changes were made.

The full coverage gate completed in 612.8 seconds (within the 900-second budget).
It includes the same versioned contract executable and all existing recovery,
reasoning, privacy, cancellation, admission, failure-identity, bounded-history
and terminal-stream regression suites. All six declared project gates passed.
Changes remain uncommitted for Foundry review; no release/version/ref changes
or edits outside mojentic-ex were made.
