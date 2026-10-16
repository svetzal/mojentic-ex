# 3.0.0 recovery conformance (partial)

This partial record now also covers the October 12 **Capabilities** amendment,
alongside the **oMLX keepalive frames** guarantee,
the **Retry-After dates** correction, the
**Admission without a hook** guarantee and preservation of the landed
**Admission without a decision** amendment.
Earlier sections preserve their execution evidence; the capabilities section
records the current correction. This does not establish full
3.0.0 readiness. The coordinated release hold remains.

## Contract identity and execution boundary

Binding source: `mojentic-unify/TRANSIENT-RECOVERY-2026-10.md`, October 12 amendment,
source repository revision `4b08dcd1d87f520a4c70928c33a2bc84c228093d`, SHA-256
`a53a3a4eb118fa4687dd703d6ce918dd40dd6cb4eda796abc6c429a6e932e7a3`.
The initiative brief was verified against SHA-256
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
The local October 9 contract copy predates this amendment; this record identifies
the binding root source rather than silently treating that copy as amended.

Reuses the existing executable ExUnit recovery mechanism: `ScriptedCompletionServer`
on loopback TCP with the production `Mojentic.HTTP.ReqClient`, actual gateway parsing,
Broker and ChatSession. No `Recovery.run` result is mocked. These are local scripted
provider observations, not proof that a real provider or another repository's
consumer satisfies the same executable contracts. The script is not a double
derived from a jointly verified producer/consumer contract set.

## Named admission checks

Preserved admission checks (originally `admission-without-decision-v1`), implemented in
`test/mojentic/llm/admission_wire_test.exs`, SHA-256
`3cbd49c76031c19b0fdf35492cb331fc89d10e619a17b1c9dfe12c602975fab8`.
This identifier is local; it is not a jointly verified cross-repository contract.
It generates 330 named cases:
`<gateway> <entrypoint> admission <outcome> preserves terminal identity and never resends`.
Gateways are OpenAI, Ollama and oMLX. Entrypoints are `complete`, `object`, `events`,
`legacy`, `broker`, `broker_object`, `broker_events`, `broker_legacy`, `session`
and `session_stream`. Outcomes cover explicit reject, nil/unexpected returns,
raise/throw/exit with a secret sentinel, untrappable worker death, callback-returned
cancelled/deadline/rejected values and an error tuple. Every case asserts:

- `:admission_no_decision` instead of caller rejection for undecided completion;
  explicit reject retains `:rejected` / `:admission_rejected`.
- Exact ordered five-event lifecycle, terminal safe metadata, original failure
  and bounded history, unchanged logical/attempt IDs and next-attempt context.
- Original wire route, model, full prior conversation, user payload and streaming
  flag, a single exact recorded request, and an independent negative observation
  for another request.
- Safe Inspect, JSON, history/context/event formatting and logs exclude callback
  and provider sentinels. Input message/session history remains intact; a failed
  streaming session cannot finalize successfully.

The prior admission-without-decision correction's real-boundary probe,
event-stream admission raising with a sentinel,
failed on the original source (`:rejected`, exit 2). The same probe passed after
the admission-only source correction (exit 0). Full matrix expansion followed
this red/green probe.

## Preservation checks

Existing `recovery_wire_test.exs` cases include:

- `<gateway> <operation> real Req pending admission requires explicit <decision>`.
- `real Req sleeper <failure> failure never enters safe errors history events or logs`.
- `ambiguous local 504 waits for explicit admission and preserves complete wire payload`.
- Deadline/cancellation in admission and backoff, plus remote/local no-hook policy.

Existing `stream_recovery_wire_test.exs` cases include:

- `<gateway> <mode> pending admission <decision> is asynchronous and never counts as a wire attempt`.
- `<gateway> <mode> cancellation during <phase> sends no subsequent request`.
- `<gateway> <mode> ambiguous local failure requires admission by default`.
- `<gateway> <mode> recovery deadline is not a total active generation timeout`.

The entire suite also covers shared CompletionRequest/StreamRecovery behavior,
immutable retry payloads, tool execution and stream terminal behavior. Shared
`Recovery.work/3`, backoff, CompletionRequest and StreamRecovery were unchanged
during the admission corrections. The date correction below changes date normalization and the reference-clock
configuration passed to it.

## Admission without a hook executable set

Local set `admission-without-hook-v1` runs with `scripts/verify-no-hook-contract`.
It prints these SHA-256 identities before executing the tagged cases:

| File | SHA-256 |
| --- | --- |
| `scripts/verify-no-hook-contract` | `dc8212d99a31adceadac364fa194223f2346680bff635cc110c3152193bafcc9` |
| `test/mojentic/llm/admission_wire_test.exs` | `3cbd49c76031c19b0fdf35492cb331fc89d10e619a17b1c9dfe12c602975fab8` |
| `test/mojentic/llm/no_hook_wire_test.exs` | `749bb5af03293686c7a10f5dec1c545447098de71901f1c1102a1790bddf2767` |
| `test/support/scripted_completion_server.ex` | `d03a3cf93eb25350bd8bf2387e70fbf7786e86e663809f55dfd7180f6e782e07` |

The 120 generated cases are named
`<gateway> <entrypoint> no hook <scenario> preserves wire and lifecycle contract`.
They cover the same three gateways and ten entrypoints listed above, with:

- `eligible`: HTTP 503 retries on OpenAI, stops with `:admission_required` on
  Ollama/oMLX. Recorded retry bytes, route, conversation and payload stay identical.
- `ineligible`: HTTP 400 never retries, despite a two-attempt configuration.
- `single_attempt`: omitted `max_attempts` retains one attempt for HTTP 503.
- `nonacceptance`: a reserved non-listening loopback socket produces real Req
  connection refusal (`:transport`, `:connecting`, `:no`, `:connection_refused`).
  Only during backoff is the scripted provider installed at that endpoint.
  Every adapter then retries without admission. Captured request bodies, URL,
  method and headers are identical across refusal and dispatched retry.

Each case verifies exact recorded requests and independently waits for an unwanted
additional request; ordered lifecycle and terminal metadata; history bounded by
the attempt limit; distinct attempt IDs under one logical request ID; eligibility,
acceptance; original session history and
failed-stream finalization. The full required `test --cover` gate executes these
cases and the preserved explicit-decision, cancellation, deadline and semantic
replay checks. No new external mock or adapter was introduced.

The 121st case is
`local event stream without admission never resends an ambiguous failure`.
Before expanding the fixtures or documentation, it passed on the existing policy.
Temporarily broadening no-hook permission to local providers caused it to reject
**two exact recorded inference requests** (exit 2). Restoring the existing policy
passed (exit 0). This is a source-regression probe through real Req, not evidence
of a previously failing production policy. No production policy correction was
needed; source changes document the established guarantee.

## Prior admission verification and coordination gaps

Tested base: `ffa67b1b05b06ad4ae429016a103e3b90b2d772f`, with the uncommitted
changes identified above. Production `lib/mojentic/llm/recovery.ex` SHA-256:
`7b649a624e0b909556823f8df92d1d3bbfe46250d28b78e4301536129c6df460`.
Runtime remains CI-pinned Elixir 1.18.5 / OTP 28.5.0.7. Foundry owns finalization;
no landed commit or cross-repository compatibility is claimed.

All `.hone-gates.json` entries were executed. Commands below use
`scripts/recovery-mix` unless a different script is named.

| Command | Exit | Result |
| --- | --- | --- |
| `format --check-formatted` | 0 | Formatted |
| `compile --warnings-as-errors` | 0 | Development compile passed |
| `MIX_ENV=test ... compile --warnings-as-errors` | 0 | Test compile passed |
| `credo --strict` | 0 | Zero issues |
| `scripts/verify-no-hook-contract` | 0 | 121 cases passed; 330 preserved decision cases excluded from this targeted run |
| `test` | 0 | 22 doctests, 3,600 tests, zero failures, 19 configured integration exclusions |
| `test --cover` | 0 | Same totals; 90.22% coverage against the unchanged 80% floor |
| `deps.audit` | 0 | No vulnerabilities reported; advisory freshness checked below |
| `hex.audit` | 0 | No retired or advisory packages reported |
| `sobelow --config` | 0 | Passed under unchanged configuration |
| `hex.outdated --all` | 1 | Informational available upgrades; no dependencies changed |
| `docs` | 0 | Built with existing link warnings described below |
| `dialyzer` | 0 | Zero errors and zero skipped warnings |
| `MIX_ENV=test ... dialyzer` | 0 | Zero errors and zero skipped warnings |

MixAudit cannot refresh the external advisory cache because its `FETCH_HEAD` is
read-only. Its installed revision `935abf7410a2bbb18e12579dee6e31267c3ed244`
was independently verified equal to upstream `main` using `git ls-remote` during
this execution. No advisory suppression or security configuration was changed.
Sobelow's existing configuration excludes `Traversal.FileModule`; this result
certifies the configured scan, not an unfiltered audit. ExDoc retains existing
warnings for the absent sibling `../RELEASE-3.0.0.md`, README `LICENSE`, and
`deps/igniter/usage-rules.md` links. No runtime or dependency versions changed.

**Missing paired verification:** no shared versioned executable producer/consumer
contract set was found for this amendment. No other repository was changed or
verified. Consumer commits, supported old/new version cases, and both sides'
verification commands/results are therefore unavailable. Coordination must provide
that set (including errors, optional fields and semantic behavior), derive doubles
from it, and run it in both repositories' required gates before compatibility is
claimed. The local suite is not a substitute for that work or a full user journey.

The Anthropic adapter is absent from mojentic-ex; its remote-provider branch
cannot be exercised here and remains a coordination gap. No adapter was added.

Remaining 3.0.0 coverage gaps include the other recovery amendments, native
reasoning, model metadata/request fidelity, and the rest of the initiative's
per-port readiness requirements. None is implemented or certified by this task.


## Retry-After dates executable set v2 (2026-10-16)

Local executable set **`retry-after-dates-v2`** extends the preserved v1 set with
RFC 850 full-timestamp cutoff regressions. All v1 three-form, malformed-date,
legacy and admission cases remain. Run `scripts/verify-retry-after-dates-contract`;
it prints the three test/support hashes below and executes both test files.
The unchanged `.hone-gates.json` `test --cover` gate executes the entire set.

| Executable source | SHA-256 |
| --- | --- |
| `scripts/verify-retry-after-dates-contract` | `174b5b70d0ca9cedf5c8df86a0803201fd3fadc4a0aed3ac4f91622bb08273bf` |
| `test/mojentic/llm/retry_after_dates_wire_test.exs` | `3693f94799a1425464ce217853943ec732caeafcbe0c8e30a916e71f1f9c54f4` |
| `test/mojentic/llm/recovery_wire_test.exs` | `b707be8df4b68b4cac10c3f2de1837443947df7a4417f94b3cf425a3a77c3f00` |
| `test/support/scripted_completion_server.ex` | `d03a3cf93eb25350bd8bf2387e70fbf7786e86e663809f55dfd7180f6e782e07` |

Binding source remains the October 12 root amendment and its previously recorded
identity above. Its SHA-256 was reverified by reading the coordinating checkout
without modifying it. The relative sibling copy is absent from this isolated
worktree. The initiative brief's recorded hash also matched in this execution.
Tested Elixir revision: `67ac83c3135476e3e003e0f169877252f399955f` plus the
uncommitted rollover correction. The preserved HEAD CompletionRequest hash was
`30365303f94f1b846c408f09befbcf9083921463a801d2e76b4844568ea91171`,
and its v1 date-test hash was
`881ec59dd02a300338c48e490bc259d606a7c146d1c39a8b69baa45e75ffdfaa`,
matching the earlier conformance record. Corrected production source SHA-256:

- `lib/mojentic/llm/completion_request.ex`:
  `3b0060739208d893eff74e1a6b41cca6b73ae66782c14b3306ed936e18934869`.
- `lib/mojentic/llm/stream_recovery.ex`:
  `800f7612133e9506692e70f67b15988fd29284634321d82681d95d2fa23bc279`.

No package, dependency or runtime version changed. Elixir 1.18.5 and OTP
28.5.0.7 remain selected by `scripts/recovery-mix` and pinned in CI.

### Production Req regression and named checks

The recipient requirement and complete 50-year rule come from
[RFC 9110 section 5.6.7](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.7).
The installed Req 0.7.5 parser accepts IMF-fixdate only. The preserved v1
normalization supplies RFC 850 and asctime support before Req's calendar/time/
weekday validation; this execution corrects only its RFC 850 century selection.

Before expanding the matrix or documentation, the new test
`RFC 850 December 2076 rolls back to 1976 through real Req` failed against the
preserved implementation: `:invalid` instead of
`{:http_date, "1976-12-31T00:00:03Z"}` (ExUnit exit 2). After the source correction,
the identical command passed (exit 0):
`... test test/mojentic/llm/retry_after_dates_wire_test.exs --only rfc850_rollover`.
It observes the policy's 7 ms delay, normalized error/history/lifecycle/admission
metadata and exact identical requests, with an independent negative observation
for an additional resend. The reference is fixed at `2026-10-16T00:00:03Z` and the
provider header is `Friday, 31-Dec-76 00:00:03 GMT`.

CompletionRequest now uses the existing recovery wall clock to compare the
candidate's complete date and time against the 50-year cutoff, before Req's
calendar/time/weekday validation. StreamRecovery passes that same recovery
configuration when constructing response metadata. The scheduling and admission
policies are unchanged. No new mock or transport adapter was introduced.

The 210 new generated cases are named
`<gateway> <entrypoint> RFC 850 <case> <scenario> compares the complete 50-year cutoff through Req`.
They use the same fixed reference and cover OpenAI, Ollama and oMLX through
`complete`, `object`, `events`, `legacy`, `broker`, `broker_object`, `broker_events`,
`broker_legacy`, `session` and `session_stream`:

- `december_rollover`: December 31 normalizes to 1976, retaining the 7 ms policy delay.
- `before_cutoff`: `Friday, 16-Oct-76 00:00:02 GMT` normalizes to 2076.
- `at_cutoff`: `Friday, 16-Oct-76 00:00:03 GMT` also normalizes to 2076.
- `after_cutoff`: `Saturday, 16-Oct-76 00:00:04 GMT` normalizes to 1976,
  retaining the 7 ms policy delay.
- `wrong_selected_weekday`: the after-cutoff timestamp with Friday is rejected
  as invalid after selecting 1976, retaining the policy delay.

Before/at cases separately prove `:retry_after_ceiling` and `:deadline` refusals:
exactly one request, no sleeper or backoff and no unauthorized resend. The
`cutoff_budget` fixture raises only its delay ceiling to let the budget decision
be reached; the default ceiling would otherwise reject first. The other scenarios
observe exactly two identical requests. Every case verifies normalized safe
metadata, unique attempt IDs, unchanged logical identity, route/model/full prior
conversation, structured schema and stream flag, unchanged session history and
failed stream finalization. Sentinel content stays out of safe metadata.

The preserved tests still cover all three date forms, future/past dates, ceiling
and budget refusals, seconds/absent/invalid headers, invalid calendar/time/weekday,
previous-century dates and ordinary/structured success. The full suite also runs
both landed admission guarantees and explicit decisions without modifying them.

### Current verification results

All commands below use `scripts/recovery-mix` with Elixir 1.18.5 and OTP
28.5.0.7 unless another executable is named. Every discovered `.hone-gates.json`
entry was executed. The existing CI already caches `priv/plts/`, which remains
ignored by Git; no gate, runtime, dependency or suppression configuration changed.

| Command | Exit | Result |
| --- | --- | --- |
| `format --check-formatted` | 0 | Passed |
| `compile --warnings-as-errors` | 0 | Passed |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | Passed |
| `credo --strict` | 0 | Zero issues |
| `test test/mojentic/llm/retry_after_dates_wire_test.exs --only rfc850_rollover` | 0 | 211 executed checks passed; 571 unrelated cases excluded |
| `scripts/verify-retry-after-dates-contract` | 0 | Local v2 consumer-side set: 1,424 tests, zero failures |
| `test` | 0 | 22 doctests, 4,394 tests, zero failures; 19 configured integration exclusions |
| `test --cover` | 0 | Same totals; 90.24% coverage against the unchanged 80% floor |
| `dialyzer` | 0 | Zero errors, skipped warnings and unnecessary skips |
| `MIX_ENV=test scripts/recovery-mix dialyzer` | 0 | Zero errors, skipped warnings and unnecessary skips |
| `deps.audit` | 0 | No vulnerabilities found; advisory freshness verified separately |
| `hex.audit` | 0 | No retired or security advisory packages found |
| `sobelow --config` | 0 | Configured scan completed; existing warnings noted below |
| `hex.outdated --all` | 1 | Informational available upgrades; no dependency changes |
| `docs` | 0 | Built; existing link warnings noted below |

MixAudit cannot refresh the read-only external cache (`FETCH_HEAD`). Its installed
revision `935abf7410a2bbb18e12579dee6e31267c3ed244` matched upstream `main` via
`git ls-remote` in this execution. No advisory suppression was added. Sobelow
retains the existing `Traversal.FileModule` exclusion; its parser warns about
quoted keywords in the unchanged lockfile. This certifies the configured scan,
not an unfiltered audit. ExDoc's existing warnings concern README `LICENSE`, the
absent relative sibling `../RELEASE-3.0.0.md`, and the
`deps/igniter/usage-rules.md` link. No unrelated fixes or upgrades were made.

### Paired verification remains unfinished

`retry-after-dates-v2` is a **local** executable-set identity, not a jointly
verified contract. Local consumer-side verification exercises gateway, Broker
and ChatSession requirements using a scripted provider. Real provider verification
against this same executable set is **missing**: no provider commit, command or
result is available. No other repository was changed or tested. Paired
consumer/provider revisions, supported old/new version semantics and optional-field
cases remain a coordination gap. Coordination must supply a shared versioned set,
derive doubles from that verified set and run verification in both repositories'
required gates. This task does not establish cross-repository compatibility,
full 3.0.0 conformance or release readiness. The coordinated release hold remains;
Foundry owns finalization and these changes remain uncommitted.

## oMLX keepalive frames: current execution

The owner-authorized objective supersedes the earlier date-only execution
restriction. Only demonstrated keepalive gaps were corrected. The binding source
and initiative hashes above were rechecked on 2026-10-16. The source checkout is
still `4b08dcd1d87f520a4c70928c33a2bc84c228093d`.

Local executable set **`omlx-keepalive-v1`** reuses ExUnit,
`ScriptedCompletionServer` and production `Mojentic.HTTP.ReqClient` (Req 0.7.5).
Run `scripts/verify-omlx-keepalive-contract`. The required project
`scripts/recovery-mix test --cover` gate includes these same cases without a tag
filter. The verifier prints each member's SHA-256. The SHA-256 of the ordered
`sha256sum` output for the following four files is
`ab812c4c020d34ebda8918763ae5378c7f97892fc81f99e252a0111b888a3a45`:

| Executable member | SHA-256 |
| --- | --- |
| `scripts/verify-omlx-keepalive-contract` | `e494f4519b099bb7a0cd9a931c097b1e92cce69186f32b379a988f8d1da501fa` |
| `test/mojentic/llm/omlx_keepalive_wire_test.exs` | `78fb3c96afb3fa7ec8b1b521a11730163e288ceeecabcf2d67a96af47f27a15f` |
| `test/mojentic/llm/stream_recovery_wire_test.exs` | `4e39ab504375ac1ab0456c8fb6731c1ce82651aa8cfa0f7601738752d5db6ab9` |
| `test/support/scripted_completion_server.ex` | `d03a3cf93eb25350bd8bf2387e70fbf7786e86e663809f55dfd7180f6e782e07` |

Consumer implementation tested: mojentic-ex base revision
`3c08290deef6c3fada9a726a8253b58a6ed886d9` plus this uncommitted correction.
Production source SHA-256:

- `lib/mojentic/llm/stream_recovery.ex`:
  `34b44c3fbbe86877d1149675818614f16b1b6e497499ebb7a0c4df0268361946`.
- `lib/mojentic/http/received_evidence.ex`:
  `0f303b19585e9e02813cf751b9e95fd858d3faf6841c525bb5c11aa3b56cb025`.

Named checks in `OMLXKeepaliveWireTest` (72 cases):

- `<entrypoint> <layout> keepalives preserve exact output metadata and progress`:
  both gateway stream APIs, both Broker stream APIs and ChatSession; coalesced
  frames and a keepalive split before, between or after real frames. The scripted
  server holds the remainder until the production Req trace confirms receipt of
  the first fragment. Assertions compare complete ordered outputs, real provider
  model and usage, exact raw bytes, observed/delivered semantic maps, lifecycle
  order and attempt identities. Exact output also excludes invented progress,
  metrics or frame-index events. oMLX exposes no public frame-index counter.
- `<entrypoint> keepalive-only truncation obeys <decision> admission without ghost
  progress`: allow, reject, undecided, raising hook, no hook and single-attempt
  policy. The keepalive deliberately includes content, reasoning, a complete
  tool and finish/usage fields; none counts as semantic evidence. Only explicit
  allow resends the identical recorded request. Errors preserve the transport
  failure, acceptance, operation, provider request ID, history and progress;
  lifecycle distinguishes rejection, no decision and required admission.
- `<entrypoint> real <semantic> before keepalive truncation forbids replay`:
  content, reasoning and tool fragments preserve exact ordered delivery and
  observed/delivered progress, interrupt without admission or another request,
  and prevent successful session finalization.
- `<mode> capture failure on keepalive retains raw bytes without semantic
  progress`: exercises actual wire-capture failure and fallback evidence in both
  gateway modes, without mocking a recovery result.
- `<mode> recovery-disabled oMLX keeps legacy keepalive semantics` and
  `<mode> minimal keepalive cannot supply completion evidence`: preserve the
  old API behavior and prove that a keepalive without optional fields cannot
  satisfy the real completion contract.

- `event stream preserves non-data SSE fields around keepalives`: confirms the
  filter preserves `event:`, `id:` and comment lines. The final implementation
  retains original complete wire lines instead of re-encoding provider frames.

Every case checks the recorded route and entire decoded request payload (model,
prior system message, user message, controls, stream flag and optional usage
request), exact replay bytes where allowed, and a negative observation for an
unauthorized request. Successful sessions retain exact final assistant history;
failed sessions retain the original history and return the stream error.

The 73rd case is the proof-first regression in `StreamRecoveryWireTest`:
`oMLX recovery ignores coalesced keepalives around real provider completion`.
Before source changes it exited **2**: keepalives polluted observed content,
reasoning and tool progress and caused a protocol failure. After the correction
the identical command exited **0**, yielding exactly content `answer` and a
completed event with real provider model and usage. Fixture and documentation
expansion followed this rejecting/passing production-boundary probe. A second
probe demonstrated ghost semantic progress on capture failure, corrected in
fallback evidence reconstruction. Keepalive bytes are counted before filtering;
OpenAI/Ollama parsing, admission and Retry-After code were not changed.

### Current verification results

`Elixir 1.18.5`, `OTP 28.5.0.7`, selected by the existing
`scripts/recovery-mix`; CI pins and runtime requirements are unchanged.

- `scripts/verify-omlx-keepalive-contract`: **pass**, 73 selected cases,
  343 excluded; both streaming APIs and public journeys exercise production Req.
- `scripts/recovery-mix format --check-formatted`: **pass**.
- `scripts/recovery-mix compile --warnings-as-errors` and
  `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors`: **pass**.
- `scripts/recovery-mix credo --strict`: **pass**, zero issues.
- `scripts/recovery-mix dialyzer`: **pass**, zero errors/skips.
- `MIX_ENV=test scripts/recovery-mix dialyzer`: **pass**, zero errors/skips.
- `scripts/recovery-mix test --cover`: **pass**, 22 doctests and 4,467 tests,
  zero failures, 19 integration cases excluded by existing project configuration.
  Coverage **90.28%**, above the unchanged **80%** threshold; elapsed 548.3 seconds.
  This final-source run includes the SSE preservation regression and all existing
  OpenAI/Ollama, legacy oMLX, admission and Retry-After regression cases.
- `scripts/recovery-mix deps.audit`: **pass**, no vulnerabilities found.
- `scripts/recovery-mix sobelow --config`: **pass**.
- `scripts/recovery-mix hex.audit`: **pass**, no retired/advisory packages.
- `scripts/recovery-mix hex.outdated --all`: exit **1**, informational updates
  available for ex_ast, finch, makeup and rustler_precompiled; no dependency
  changes or advisory suppressions were made.
- `scripts/recovery-mix docs`: **pass** (exit 0), retaining existing unresolved
  links to `../RELEASE-3.0.0.md`, `LICENSE` and `deps/igniter/usage-rules.md`.
  These are documentation warnings, not a claim of a warning-free docs build.
- No `precommit` alias is defined. CI already pins the runtime and caches
  `priv/plts/`, which is already ignored.

### Paired provider verification: coordination gap

This is a versioned **local consumer executable set**, not a jointly verified
cross-repository contract. oMLX provider revision: **not verified**. Provider-side
command/result against this same set: **not available / not run**. No external
consumer repository was changed or verified. The script responses are local
boundary observations, not doubles derived from a mutually verified provider
contract. Coordination must supply a provider verifier for these same identified
cases and record its tested revision and result before claiming compatibility.
Supported provider-version coverage is therefore unverified; neither schema
matching nor these local passing cases establishes compatibility. Paired
verification remains unfinished initiative work. Full 3.0.0 readiness and release
remain on hold.


## October 16 capabilities correction (partial)

### Scope and inspected evidence

Binding amendment and initiative brief hashes remain those recorded above; both
were freshly checked against their supplied SHA-256 values. Tested source starts
at Elixir revision `663fc25a6ffca3d7a0f11d02e2ab11b26d672be4` plus this
uncommitted correction. Foundry owns finalization. No dependencies, runtime pins,
versions, HTTP adapters, recovery policies or sibling repositories were changed.
CI remains pinned to Elixir **1.18.5**, OTP **28.5.0.7**, with cached project PLTs.

The changed boundary is the pure public declaration API, not an inference HTTP
request. The initial public `Recovery.capabilities/1` characterization passed
three exact-map assertions: all adapters returned local cancellation supported,
remote cancellation/status/idempotency unsupported, exact-attempt termination
unknown. There was no evidence accessor. Unsupported providers raised
`FunctionClauseError`. No provider-specific distinction or cited evidence existed.

The correction preserves the five names and atom-valued map and adds
`Recovery.capability_evidence/1`. Each of its 15 entries supplies value, exact
method/default URL, inspected provider documentation URL, ISO inspection date
and a facility-specific interpretation. Each atom value is projected from that
same production declaration to prevent drift. Tests assert the full evidence
record against an explicit versioned expected set, including every field, every
value and every named capability for every adapter, plus the unsupported-provider
error boundary. No mocks or additional HTTP facilities are introduced.

The October 16 inspection and provider capability table are in
[the streaming guide](guides/streaming.md#completion-recovery-capability-evidence).
Sources: OpenAI Chat Completions operation and streaming-event references,
Ollama chat endpoint and provider SDK abort documentation, and oMLX README API
inventory at provider source revision
`53ab0e66d75fe46e3cfa7ed7a7762d3bbcf21e9c` (documentation inspection only).
Stored OpenAI result retrieval/deletion is not in-flight status/cancellation;
Ollama keep_alive is not a per-request cancellation facility. oMLX protocol
compatibility does not establish cancellation or idempotency semantics.

Migration: oMLX local cancellation and idempotency declarations now read
`:unknown`, reflecting ambiguous documentation. The adapter still cancels locally.
All three exact-attempt termination values remain unknown. Admission, Retry-After,
keepalive, local cancellation implementation, legacy APIs and OpenAI/Ollama
recovery behavior are preserved. Other amendments, reasoning and metadata are
outside this execution. Earlier capability assessments describe historical
observations; the current cited declarations supersede them.

### Executable identity and proof

Local executable set: **recovery-capabilities-v1**.

- Expected declarations: `test/contracts/recovery_capabilities_v1.json`, SHA-256
  `40e8da683ce4bfcfebf9892ca51a53a701488d463977f021922cd6317203aa76`.
- ExUnit verifier: `test/mojentic/llm/recovery_capabilities_test.exs`, SHA-256
  `5d703fff9aede786d4ef9388dce2b2ef2b2ec01a77f6a1a93fa68bdf5024468a`.
- Command: `scripts/recovery-mix test test/mojentic/llm/recovery_capabilities_test.exs`.
  Original-source verification: exit **2**, 20 tests, 16 failures, demonstrating
  missing evidence rather than an artificial marker. Corrected source: exit
  **0**, 20 tests, no failures. The earlier minimal original-source probe also
  rejected the unsupported claim of documented oMLX local cancellation (exit 2)
  and passed after correcting that declaration (exit 0), before expanding the set.
- Existing ExUnit discovery runs this same verifier in the required test gate;
  no separate schema-only check or independently authored provider mock is used.

The original five-key atom representation remains supported. No earlier
versioned capability-evidence protocol exists in this repository; v1 adds evidence
without replacing the old representation. Unknown facilities never establish
resend permission or exact remote termination. Wire integration tests still cover
the user's completion journey separately from these declaration assertions.

### Paired verification remains unfinished

This is a **local declaration contract**, not jointly verified provider/consumer
compatibility. For OpenAI, Ollama and oMLX, provider implementation revision tested:
**none**; provider verification command/result against recovery-capabilities-v1:
**unavailable / not run**. The oMLX documentation revision above is not a tested
provider implementation revision. External consumer revisions and their verifier
commands/results are likewise **unavailable / not run**. Elixir verified the
public declaration API at the source revision and working changes identified
above; it did not establish live-provider behavior from documentation or mocks.

Coordination finding: each affected provider/consumer side must verify the same
identified executable set and report its tested revision, command and result
before paired conformance can be claimed. Such verification or required adapters
must be coordinated as separate authorized work; no sibling repository was edited.
This missing verification is unfinished coordination work. The six-port release
hold remains; this correction does not establish complete 3.0.0 readiness.

### Current quality checks

All commands use `scripts/recovery-mix` and the existing pinned runtime.
Fresh command results (zero means pass):

| Command | Exit | Result |
| --- | --- | --- |
| `format --check-formatted` | 0 | Final source formatted |
| `compile --warnings-as-errors` | 0 | Final development compilation |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | Final test compilation |
| `credo --strict` | 0 | Zero warnings on final source |
| `test` | 0 | 22 doctests, 4,487 tests, zero failures; 19 existing integration exclusions |
| `test --cover` | 0 | Final source: 22 doctests, 4,487 tests, zero failures, 19 existing exclusions; 90.32% coverage above unchanged 80% threshold |
| `dialyzer` | 0 | Zero errors, skips or unnecessary skips; project PLT reused |
| `deps.audit` | 0 | No vulnerabilities found; advisory freshness qualified below |
| `hex.audit` | 0 | No retired or security-advisory packages |
| `sobelow --config` | 0 | Configured non-Phoenix scan; qualifications below |
| `hex.outdated --all` | 1 | Informational available upgrades; no dependencies changed |
| `docs` | 0 | Built with existing unresolved-link warnings |

Initial strict Credo exposed two alias-placement issues, which were corrected;
the final strict run and both compilation environments passed. The exact final
citation set was also checked against original source (exit 2, 16 failed checks)
and corrected source (exit 0, all 20 checks passed). The final fixture uses the
inspected README's actual `api-compatibility` anchor. No thresholds or exclusions
were changed to obtain a passing result. There is no precommit alias.

MixAudit's attempted cache refresh was denied by the read-only external
`FETCH_HEAD`. The clean installed advisory repository revision
`935abf7410a2bbb18e12579dee6e31267c3ed244` was independently compared with
`git ls-remote https://github.com/mirego/elixir-security-advisories.git refs/heads/main`
(exit 0) and matched upstream in this execution. No advisory suppression or
allowlist was added or modified. Sobelow retains its pre-existing configured
`Traversal.FileModule` exclusion, warns about a missing Phoenix router (this is
not a Phoenix project), and emits parser warnings for the unchanged lockfile's
quoted keywords. Its successful exit describes the configured scan only.

ExDoc retains existing unresolved links to `LICENSE`, the unavailable relative
sibling `../RELEASE-3.0.0.md`, and `deps/igniter/usage-rules.md`. The outdated check
reports updates for ex_ast, finch, makeup, rustler, rustler_precompiled, sourceror
and spitfire; this informational result does not identify a security advisory.
No runtime or dependency upgrade, suppression, version change or release action
was taken. Proof JSON field types, actual red/green exit codes, referenced log
existence and executable fixture/verifier hashes were validated. Execution logs
and proof remain Foundry-owned scratch, not project artifacts.
