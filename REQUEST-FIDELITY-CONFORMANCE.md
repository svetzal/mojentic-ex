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

## Tested identities and gate results

The following manifest and results describe the uncommitted Foundry review
snapshot; the commit identity alone does not include these source changes.

Git base (both local sides): `98b54a0cf0b028b82d38655ac59ebafcd7988077`,
plus this uncommitted source snapshot:

| Artifact | SHA-256 |
| --- | --- |
| `test/contracts/request_fidelity_v1.json` | `6f02088311f50707b9c12154d888f844928c23d359043cb2e5d5654bf7e5eaea` |
| `test/mojentic/llm/immutable_request_wire_test.exs` | `155860aece0aa423fee5ab172b62d61c014e5b4edeb3daec7fad45f45a51f5fb` |
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

The tracked behavioral patch (`git diff --binary -- lib test | sha256sum`) is
`2681fc51a977fae68e20bb06fc29ffc0eb5f60e6e40ea9a4286ca2c7b92c70ab`;
untracked contract JSON and runner identities are listed separately above.
Both local sides test that same base plus snapshot, rather than an unmodified
released commit.

The proof-first probe used production Req, a completed tool call, a 503 requiring
admission and a final answer. On the original source it failed (exit 2) because
the exact body contained temperature 1.0, num_ctx 32,768 and num_predict 16,384.
Removing config defaults and adapter fallbacks made the same probe pass (exit 0).
The final expanded probe passes for all three maintained adapters, checks the
single tool outcome, and compares continuation replay bytes exactly.

The full-suite fixture audit also updated `OMLXKeepaliveWireTest.assert_requests/3`
to expect omitted defaults. Its keepalive semantics, metadata, admission, terminal
progress and exact replay assertions remain unchanged. The focused keepalive
contract passed after that fixture correction.

| Verification side | Tested source | Command | Result |
| --- | --- | --- | --- |
| Maintained OpenAI/Ollama/oMLX adapter implementations | Base plus production source hashes above | `scripts/verify-request-fidelity-contract` | Exit 0; 348 tests in the shared set, including direct gateway cases |
| Broker/ChatSession consumers in mojentic-ex | Same base, production and executable hashes | Same `scripts/verify-request-fidelity-contract` | Exit 0; same 348-test run includes matching Broker cases, supported session paths, tool outcomes and tracing |
| External provider implementations and cross-repository consumers | Not tested in this authorized worktree | Not run | Missing verification; coordinate separately, no paired compatibility claim |

All project commands below use the unchanged pinned runtime through
`scripts/recovery-mix` and were executed through Foundry capture. The dedicated
contract set and focused keepalive suite passed with 348 and 72 tests respectively.

| Gate / applicable check | Result |
| --- | --- |
| `format --check-formatted` | Exit 0 |
| `compile --warnings-as-errors` (development and test environments) | Exit 0 |
| `credo --strict` | Exit 0; zero issues |
| `dialyzer` (development and test environments) | Exit 0; zero errors, skipped errors or unnecessary skips |
| `deps.audit` | Exit 0; no vulnerabilities found |
| `hex.audit` | Exit 0; no retired or security-advisory packages |
| `sobelow --config` | Exit 0; existing configuration unchanged |
| `docs` | Exit 0; guides and API docs build |
| `hex.outdated --all` | Exit 1 reporting available updates; informational, no upgrades made under the dependency hold |

The docs build retains existing unresolved links to `../RELEASE-3.0.0.md`,
`LICENSE` and `deps/igniter/usage-rules.md` in the isolated documentation inputs.
No warning suppression or unrelated documentation/dependency changes were made.

Final full project gate: `scripts/recovery-mix test --cover` exited 0 with
**22 doctests, 4,998 tests, zero failures, 19 excluded integration tests**.
Coverage was **90.60%**, above the configured 80% threshold; execution took
590.8 seconds, within the 900-second gate budget. This command executes the
complete default `mix test` suite with coverage, including the same executable
request-fidelity contract and the corrected keepalive fixture.

The required format, compile, strict Credo, full test/coverage, dependency audit
and Sobelow gates all passed on the final implementation. No Git finalization,
version bump, release or changes outside mojentic-ex were performed.
