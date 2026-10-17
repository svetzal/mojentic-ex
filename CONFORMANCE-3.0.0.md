# 3.0.0 conformance (partial)

The final section records client first-token timing and its external verification gaps.
This partial recovery record also covers the October 12 **Typed errors** guarantee
and the **Capabilities** amendment,
alongside the **oMLX keepalive frames** guarantee,
the **Retry-After dates** correction, the
**Admission without a hook** guarantee and preservation of the landed
**Admission without a decision** amendment.
Earlier sections preserve their execution evidence; the capabilities section
records that correction; the typed-errors section records this execution. This does not establish full
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

## October 16 typed errors correction (partial)

Only the October 12 **Typed errors** guarantee is addressed by this execution.
The binding source revision `4b08dcd1d87f520a4c70928c33a2bc84c228093d` was read
from the source repository and its file hash independently verified as
`a53a3a4eb118fa4687dd703d6ce918dd40dd6cb4eda796abc6c429a6e932e7a3`.
The Foundry initiative brief hash was independently verified as
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
Tested Elixir source is base commit
`b85a27ab37bd16e6ee82950ea08f00c5356c5075` plus the uncommitted changes in this
execution. No refs, versions, runtime pins or dependencies were changed.

### Characterization and corrections

The production-Req probe `session retains typed length failure through the real
Req boundary` rejected the original implementation (exit 2): ChatSession returned
`{:error, {:incomplete_completion, "length"}}` outside the typed completion error.
After correction the same probe passed (exit 0), retaining the exact received
body and the `{:incomplete_completion, "length"}` cause inside `CompletionError`.
This rejecting case was an assertion failure after an actual HTTP request, not
the earlier dependency-restoration failure. Fixture expansion followed this
red/green check.

The policy probe `invalid session stream policy is a typed policy failure` also
rejected the original category (exit 2). The expanded matrix exposed compatible
legacy streams losing length to `:invalid_stream_event` (exit 2). Corrections:

- Invalid policies use the idiomatic discriminated type
  `%CompletionError{category: :policy, reason: :unsupported_options}` everywhere.
  The existing stable reason and retained cause remain `:unsupported_options`;
  policy values are never retained. Acceptance is `:no`, wire attempts are zero,
  and history is empty. No new wrapper can be swallowed by Broker streaming.
- Ordinary recovery rejects provider length termination before parsing structured
  content or tools, including invalid truncated object JSON. Its category is
  `:protocol`, reason `:incomplete_completion`, and retained cause
  `{:incomplete_completion, "length"}`. This prevents Broker's otherwise untyped
  tuple and prevents a structured parse error from replacing the length cause.
- Recovery-enabled OpenAI/oMLX legacy streams retain the same length cause before
  `[DONE]` can replace it. A rejected terminal frame does not complete tools.
  Event streams retain their existing typed incomplete-completion evidence map;
  semantic output may still set safe reason `:stream_interrupted`.
- Capture failures already propagated as `CompletionError` through these public
  boundaries, retaining `:capture_failed`. The capture boundary intentionally
  discards callback exception messages; no original callback exception is claimed
  as retained. No capture production change was justified by characterization.

The correction does not change recovery-disabled APIs, including successful
legacy oMLX ordinary length responses. Existing admission, capability, Retry-After,
keepalive, cancellation and bounded-history suites remain required preservation
checks. Reasoning, metadata and other amendments remain outside this objective.

### Executable boundary contract and verification limits

Local executable set: **typed-errors-v1**, implemented in
`test/mojentic/llm/typed_errors_wire_test.exs`. It reuses the existing
`ScriptedCompletionServer` and production `ReqClient` mechanism, actual gateway
parsers, Broker and ChatSession. ExUnit discovery runs it in the normal required
`test --cover` gate. The file hash and final command results are recorded below.

Named cases include:

- `<gateway> <entrypoint> <policy|capture|length> retains typed cause and forbids replay`:
  99 cases over OpenAI, Ollama and oMLX; ordinary, object, event and legacy gateway
  calls; ordinary, native response, object, event and legacy Broker calls; session send and stream.
  Each policy case exercises eight malformed policies, callback arity, unknown
  options, invalid statuses and invalid categories, asserting the concrete typed
  discriminator and retained cause, zero dispatch and safe metadata.
- `<gateway> <object|broker_object> truncated JSON retains length rather than a parser error`:
  six cases preserve the concrete incomplete-completion cause and exact body.
- `<gateway> legacy ordinary length response remains successful without recovery`:
  three cases preserve the successful response and reported finish reason.
- The two named red/green probes above remain executable regression cases.

Failure cases assert concrete `CompletionError` values and original causes,
non-retryability, admission never invoked, no second request and no tool execution
(including completed ordinary tool calls and legacy terminal tool fragments).
They compare exact recorded request bodies with opt-in trace bodies, assert the
full ordered prior conversation and query, model, bounded one-attempt history,
logical and attempt identity, safe lifecycle terminal metadata and privacy.
Streams have exactly one terminal error, no successful completion, and failed
session finalization returns that same error. Raw received stream frames are
verified through opt-in trace data; protocol stream errors do not promise raw
frames in `received_evidence/1`. Ordinary received bodies are checked exactly.

This is a **local executable contract**, not a jointly verified cross-repository
contract. No external wire schema or provider endpoint was changed. The public
Elixir error category and recovery length behavior changed; external consumers
must coordinate matching and cause handling against this same executable set.
No shared paired verifier currently exists for this boundary. Provider
implementation commits tested for OpenAI/Ollama/oMLX: **none**. Their verification
commands/results against typed-errors-v1: **unavailable / not run**. External
consumer commits, commands and verification results: **unavailable / not run**.
Local scripted responses are not doubles derived from jointly verified provider
contracts, and independent mocks are not compatibility evidence. Missing paired
verification remains unfinished coordination work in separately authorized
repositories. No other repository was edited. The six-port release hold remains;
this partial result does not establish full 3.0.0 readiness.

Executable set SHA-256 (fixture, invocation and assertions together):
`0f8deb376a9382012431320f1b26361cb0cc898863443e3bcea8ed587b3f3af9`.
The focused verifier command
`scripts/recovery-mix test test/mojentic/llm/typed_errors_wire_test.exs`
passed with **110 tests, zero failures**. Its captured stdout was separately
checked for `capture-secret`, `input-sentinel` and `tool-secret`, with none found.

The idiomatic policy representation is a discriminated `CompletionError`, rather
than a separate exception class; callers can match the struct and `:policy`
category directly. This preserves the existing reason atom and streaming error
propagation. No contract ambiguity requiring a root amendment was identified;
the genuine outstanding gap is paired external verification.

An additional baseline comparison ran the **same final 110-case set** after
loading `CompletionRequest` and `StreamRecovery` directly from `git show
b85a27ab37bd16e6ee82950ea08f00c5356c5075:<module path>` into a separate VM.
It used `MIX_ENV=test scripts/recovery-mix run --no-compile --no-start` with
`-r` for the temporary original-module source and
`-e 'Mix.Task.run("test", ["--no-compile", "test/mojentic/llm/typed_errors_wire_test.exs"])'`.
No source or compiled artifact in the working tree was replaced. That comparison
returned **exit 2: 110 tests, 65 failures**: 34 policy cases/probe and 31 length
cases/probe, including truncated structured content. All 33 capture cases,
nine already-conforming length stream cases and three recovery-disabled legacy
checks passed against original code. Expected module-redefinition warnings were
confined to this diagnostic VM; they were not suppressed. The corrected final
set returned **exit 0: 110 tests, zero failures** under its normal test command.
This additional comparison supplements, rather than replaces, the initial
before-correction red/green proof.

### Fresh execution quality results

All Mix commands below use `scripts/recovery-mix`, which verifies the existing
CI pins: Elixir **1.18.5**, Erlang/OTP **28.5.0.7**. CI already caches project
PLTs in `priv/plts/`, and that path is already ignored. This run built a fresh
PLT without changing those settings. No precommit alias exists.

The first strict Credo run found one oversized test helper; it was split into
wire and lifecycle assertions, and strict Credo then passed with zero warnings.
A full-suite run loaded an earlier lifecycle assertion that incorrectly expected
`:yes` acceptance for length-terminated streams. It produced 15 assertion
failures; the model deliberately retains `:unknown` there. The assertion was
corrected without changing production acceptance behavior. The corrected focused
suite passed all 101 tests before the final full-suite runs.

Additional completed checks:

| Command | Exit | Result |
| --- | --- | --- |
| `scripts/recovery-mix dialyzer` | 0 | Zero errors, skips or unnecessary skips |
| `scripts/recovery-mix deps.audit` | 0 | No vulnerabilities found; freshness qualified below |
| `scripts/recovery-mix hex.audit` | 0 | No retired or security-advisory packages |
| `scripts/recovery-mix sobelow --config` | 0 | Existing configured scan; qualifications below |
| `scripts/recovery-mix hex.outdated --all` | 1 | Informational available updates; no dependencies changed |
| `scripts/recovery-mix docs` | 0 | Built with existing unresolved-link warnings |

MixAudit's attempted advisory refresh could not open the external read-only
`.git/FETCH_HEAD`. The installed advisory repository revision
`935abf7410a2bbb18e12579dee6e31267c3ed244` was independently compared with
`git ls-remote https://github.com/mirego/elixir-security-advisories.git refs/heads/main`
(exit 0) and matched upstream during this execution. Its successful audit is
qualified by that refresh failure and independent freshness check. No advisory
suppression or allowlist was added or modified.

Sobelow retains the pre-existing `Traversal.FileModule` exclusion. It warns
about the absence of a Phoenix router (this library is not a Phoenix project)
and emits quoted-keyword parser warnings for the unchanged lockfile. Its exit 0
describes that configured scan, not an expanded audit scope. ExDoc retains its
existing unresolved links to `LICENSE`, `../RELEASE-3.0.0.md` and
`deps/igniter/usage-rules.md`; no new unresolved links were reported. The outdated
check is informational, not a vulnerability finding. No threshold or exclusion
was lowered to obtain a passing result.

The final public-API review added `Broker.generate_response/4` to the matrix,
including policy, capture and length checks across all three adapters. No further
production change was needed. Strict Credo was rerun and again passed with zero
warnings. The full plain test run before this final nine-case addition passed
with **22 doctests, 4,588 tests, zero failures and 19 existing integration
exclusions**. The first passing coverage run also loaded the earlier set: 4,588 tests,
90.33% coverage (exit 0). Because the final nine cases had not been loaded in
that run, fresh full plain and coverage runs were started against the final
110-case fixture. Their results are recorded below.

Both local sides execute the same typed-errors-v1 verifier command and hash above,
against base `b85a27ab37bd16e6ee82950ea08f00c5356c5075` plus these working changes:

| Local side | Verification result |
| --- | --- |
| Actual public gateway adapters (OpenAI, Ollama, oMLX) | 42 gateway cases pass within the same 110-case verifier |
| Actual Broker and ChatSession consumers | 68 consumer cases pass within that verifier |
| External provider implementations / external repository consumers | Not run; commits unavailable; paired cross-repository verification unfinished |

The script provides received HTTP observations for exercising local adapters;
it remains unverified against real external providers. This table does not
convert scripted observations into an external provider compatibility claim.

Final required checks against the complete final fixture:

| Command | Exit | Result |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | Final source formatted |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | Final development compilation |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | Final test compilation |
| `scripts/recovery-mix credo --strict` | 0 | Zero warnings on final source and fixture |
| `scripts/recovery-mix test` | 0 | 22 doctests, 4,597 tests, zero failures, 19 existing integration exclusions; 551.3 seconds |
| `scripts/recovery-mix test --cover` | 0 | 22 doctests, 4,597 tests, zero failures, 19 existing exclusions; 551.4 seconds; **90.33%** coverage above the unchanged **80%** threshold |

Both final full runs include all 110 typed-errors-v1 cases, including the native
Broker response entrypoint. The focused verifier and original-code comparison
use the same final executable set hash recorded above. The real-boundary
behavioral proof JSON was validated for exact field names and types, nonempty
source-change description, actual rejecting exit 2 and corrected exit 0,
matching preserved source logs and existence of both referenced log files.
Final validation also checks the executable-set hash against this record, focused
privacy sentinels, all quality outcomes, unchanged runtime/dependency/release
configuration, a clean whitespace diff and nonempty uncommitted source changes.
Execution logs and proof are Foundry-owned scratch, not committed project
artifacts. Foundry owns Git finalization; no commit, push, ref change, version
bump, publication or release was performed.

## Part 2: native reasoning (local implementation; external verification pending)

Binding source: `mojentic-unify/REASONING-PROTOTYPE-2026-10.md`, source revision
`4b08dcd1d87f520a4c70928c33a2bc84c228093d`, SHA-256
`0a40f3ad45c593bc779411021e45db569e73d3ecce86c99b201e7f8ebb656809`.
The initiative brief SHA-256 was verified as
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
Rust was inspected read-only at `6b5895be44fd9f81196d2004900f2059bc71c3ce`
(the release brief identifies the original prototype as `67791b7`). No Rust tests
were run or changed here. Elixir tested base revision:
`ddb2217c8245b041a20fd25f34f5aa6fbfaee2ce`, plus this uncommitted part-2 patch.
No version, dependency, runtime or Git ref was changed.

### Executable contract identity

`native-reasoning-v1` reuses the loopback `ScriptedCompletionServer` and production
Req boundary. `scripts/verify-native-reasoning-contract` prints the version and
SHA-256 manifest, then runs `test/mojentic/llm/reasoning_wire_test.exs`.
`test/contracts/native_reasoning_v1.json` supplies the exact control matrix,
reasoning/content values, tool-call identity/arguments and tool result. Scripted
responses are derived from those cases. This is a locally verified contract set,
not an independently verified real model provider. The same tests run in the
required `test --cover` gate and pinned CI coverage job.

The initial public-boundary probe executed a real oMLX Broker tool continuation.
Before correction it failed (exit 2): the next HTTP request omitted the completed
assistant's native reasoning. After correction the same probe passed (exit 0),
asserting the entire ordered continuation payload, exact tool-call identity and
arguments, a single execution, and `preserve_thinking` on both requests. Matrix
expansion and documentation followed that behavioral correction.

### Contract decisions mapped to named executable cases

All names below are in `reasoning_wire_test.exs`; generated names include the
provider, entrypoint and effort/outcome.

| Contract decision | Named test pattern and semantic assertions |
| --- | --- |
| Native reasoning separate from content/tools | `completed native reasoning and exact tool identity survive a real Req continuation`; entire ordered user/assistant/tool payload and exact execution arguments |
| Six distinct efforts and omitted unknown | `<gateway> <operation> sends exact <effort> control and native history`; all six and nil over ordinary, structured, legacy-stream and terminal-event APIs, exact values and omitted keys |
| Caller-selected profiles; no name inference | `<gateway> <operation> validates caller-selected profile before HTTP`; zero requests for unsupported effort/history; `invalid reasoning configuration fails before HTTP` |
| Exact Qwen3.8 capability | `<gateway> Qwen3.8 accepts exact <effort> on an unrelated model name`; nil/disabled/low/medium/xhigh accepted, enabled/high rejected by the profile tests |
| Opt-in ordinary and streamed tool retention | `<gateway> <operation> tool continuation retains native reasoning only with preserve=<boolean>`; exact full ordered continuation, tools and results, default off and successful on |
| Completed native history only | `<gateway> <failure> stream never executes tools or fabricates a continuation`; interrupted, length and consumer cancellation after native reasoning is observed through ChatSession, unchanged input history, failed finalization and no tool execution or second request; `<gateway> incomplete ordinary native turn cannot execute tools or retain history` |
| oMLX preserve_thinking; effort independent of retention | `<gateway> <operation> requests native retention without inventing effort`; exact preserve request on all four entrypoints, effort keys absent; tool-continuation cases check every round |
| Native stream reasoning | `<gateway> legacy stream exposes native reasoning separately through validated Req`; ordered reasoning/content/tools and exact identity; retained streams use one validated request |
| Structured controls and response reasoning | `... object sends exact ...`, `... object validates ...` and `... object requests native retention ...` use actual Req and structured decoding; `<gateway> structured response keeps native reasoning outside the JSON object` verifies separate native reasoning in the returned response |
| OpenAI extension rejection and legacy compatibility | `OpenAI <operation> explicitly rejects new controls and native history before HTTP`; zero dispatch; `OpenAI preserves legacy <effort> effort and history through Req` checks nil/low/medium/high and exact history without local-provider extensions |
| ChatSession controls and visible history | `ChatSession ordinary and stream paths forward exact controls and validate profiles`; `legacy ChatSession stores visible content separately from native stream reasoning`; finalization excludes thinking from visible content |

Native retention uses the existing validated streaming parser when enabled, even
without a recovery policy; this is one attempt and never opts into resends.
Legacy local streams now expose separate thinking tuples. The single-turn
terminal-event API retains its existing event shape. Manual outer-turn native
history uses completed `generate_response/4` results; ChatSession retains its
existing bounded visible-answer history. No native history is synthesized from
partial/error/cancelled turns. OpenAI history adaptation remains unchanged.

### External verification gaps for coordination

Local adapter/provider verification and Broker/ChatSession consumer verification
use the same executable set above. They exercise production HTTP serialization,
parsing and tool execution against contract-derived scripted responses. They do
not establish that actual Ollama/oMLX servers or external repository consumers
satisfy this set. No external tested consumer revision or verification command
result is available. Paired cross-repository verification is unfinished and must
be assigned separately using `native-reasoning-v1` and its manifest; do not infer
it from schemas, these fixtures, or Rust's prior prototype tests. In particular,
forced oMLX server settings may override `preserve_thinking`; this run verifies
the request, not server enforcement or stochastic model efficacy.

The separately assigned `typed-errors-v1` consumer follow-up is unchanged and is
not a blocker for this port's native-reasoning implementation. Parts 1 and 3 and
the other ports retain their own readiness work. This partial record does not
authorize release; the coordinated hold remains.

### Native-reasoning-v1 manifest for this patch

| Executable contract artifact | SHA-256 |
| --- | --- |
| `test/contracts/native_reasoning_v1.json` | `be212ff011125f1d0927e3a65a0d7cd87eedbf9f5ff69e803b4112a80ae6b1f6` |
| `test/mojentic/llm/reasoning_wire_test.exs` | `67d94c295e52e63649586716c4b3c167549f37c0be757c829accac72c30fdee4` |
| `test/support/scripted_completion_server.ex` | `d03a3cf93eb25350bd8bf2387e70fbf7786e86e663809f55dfd7180f6e782e07` |
| `test/support/counting_tool.ex` | `87eed78d78cd23be5082bfe504af1322127019f064f69b9179c4428c923fe194` |

The effort/history and profile-validation matrices run the **same cases** both
through direct gateway APIs (provider-adapter verification) and through public
Broker APIs (consumer verification), including structured and both streaming
APIs. Their generated names include `gateway` or `broker`. The tool-continuation
checks compare the entire ordered message payload and require every other
request field to remain identical across rounds. Missing native reasoning stays
omitted, including with retention enabled.

An additional production-Req characterization found that Ollama structured
responses dropped `thinking`: the structured-reasoning probe failed (exit 2)
with `thinking: nil`, then passed (exit 0) after mapping the native response
field separately from content and the decoded object. oMLX already conformed.
The probe command was `scripts/recovery-mix test
test/mojentic/llm/reasoning_wire_test.exs --only structured_reasoning`.

The production source snapshot has manifest digest
`05b5a5734a4cfff6433ebf5487763eb93c31d1d5cfcee87e39e0124f546837d4`.
Reproduce it with Bash, from the repository root:

```bash
sha256sum lib/mojentic/llm/{broker,chat_session,completion_config,message,reasoning,reasoning_profile}.ex \
  lib/mojentic/llm/gateways/{ollama,omlx,openai,openai_legacy_stream}.ex | sha256sum
```

This identifies the tested uncommitted implementation on the Elixir base revision
above; it is not a release commit. External repositories were inspected only as
read-only references and have no verification result from this execution.

Ollama's recovery-disabled cold legacy stream still re-enumerates its underlying
HTTP body, as explicitly characterized by the existing immutable-request and
stream-recovery tests. That unrelated behavior is preserved in this scope.
Native-retention streams use the existing validated parser with one attempt.
The Ollama legacy effort matrix selects `recovery: []` (one attempt, no resend)
to exercise its validated legacy API; the immutable-request tests separately
verify the changed exact `"high"` control, now including structured output, on
the recovery-disabled legacy path and identical admitted retry payloads.

### Final native-reasoning verification results

Pinned runtime: Elixir **1.18.5**, Erlang/OTP **28.5.0.7**, selected and checked by
`scripts/recovery-mix`, matching the existing CI pins. No runtime upgrade was made.
All commands below completed against the base revision plus the production and
contract snapshots identified above.

| Command | Result |
| --- | --- |
| `scripts/recovery-mix format --check-formatted` | Exit 0 |
| `scripts/recovery-mix compile --warnings-as-errors` | Exit 0, no project warnings |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | Exit 0, no project warnings |
| `scripts/recovery-mix credo --strict` | Exit 0, zero issues |
| `scripts/recovery-mix dialyzer` | Exit 0, zero errors/skips |
| `MIX_ENV=test scripts/recovery-mix dialyzer` | Exit 0, zero errors/skips |
| `scripts/recovery-mix test` | Exit 0; 22 doctests, 4,779 tests, zero failures, 19 excluded; 628.9 seconds |
| `scripts/recovery-mix test --cover` | Exit 0; same counts, **90.60%** total coverage against 80% threshold; 558.4 seconds (below the 900-second gate limit) |
| `scripts/recovery-mix deps.audit` | Exit 0; no vulnerabilities |
| `scripts/recovery-mix sobelow --config` | Exit 0; no findings |
| `scripts/recovery-mix hex.audit` | Exit 0; no retired or security advisory packages |
| `scripts/recovery-mix hex.outdated --all` | Exit 1; available upgrades reported, informational/nonblocking. No advisory was suppressed and no dependencies changed. |
| `scripts/recovery-mix docs` | Exit 0; existing unresolved links to the sibling release plan, README's LICENSE and dependency usage-rules file remain. Native reasoning guides build. |

The 19 exclusions are the repository's existing integration-tag exclusions;
this execution does not claim real model-server, registry-install or stochastic
benchmark verification. No `precommit` alias is defined. CI already caches
`priv/plts` and runs these tests with its pinned runtime; that configuration was
preserved. All `.hone-gates.json` commands, including its optional audit and
Sobelow commands, passed. No advisory suppressions, dependencies, versions or
Git refs were changed. Changes remain uncommitted for Foundry review.

| Verification side | Tested revision | Same executable set and command | Result |
| --- | --- | --- | --- |
| Maintained gateway/provider adapters | Elixir `ddb2217c8245b041a20fd25f34f5aa6fbfaee2ce` plus the source snapshot above | `native-reasoning-v1`; `scripts/verify-native-reasoning-contract` | Exit 0; all 182 named cases passed, including direct gateway control/history and profile matrices |
| Broker/ChatSession consumers in this repository | Same Elixir base and source snapshot | Same `native-reasoning-v1` command and artifact manifest | Exit 0; all 182 named cases passed, including the identical Broker matrices, tool continuations and session outcomes |
| Actual model-server producers | No tested revision/version available | Same set must be verified in separately authorized coordination | Not run; external verification gap |
| External repository consumers | No tested revision available | Same set must be verified in separately authorized coordination | Not run; external verification gap |

The final minimal acceptance command,
`scripts/recovery-mix test test/mojentic/llm/reasoning_wire_test.exs --only reasoning_proof`,
also passed (exit 0) on this final snapshot: one selected case, 181 excluded.
These results establish the declared local adapter/consumer cases only; paired
external verification remains unfinished. The independent `typed-errors-v1`
consumer follow-up retains its separate assignment.

## Request fidelity — partial part 3 evidence

The request-fidelity correction implemented only MODEL-METADATA-2026-10 sections 3–3.6
(SHA-256 `a085da1c0d110f9d587a24ace6ac2854b653e1ac28905b3829d94d665b2c906e`).
`temperature`, `num_ctx` and `max_tokens` are optional without defaults;
`CompletionConfig.num_predict` is removed. See
[REQUEST-FIDELITY-CONFORMANCE.md](REQUEST-FIDELITY-CONFORMANCE.md) for the
characterized public boundary, `request-fidelity-v1` executable manifest, named
exact-body and replay cases, local adapter/consumer identities and results,
changed-default migration profile and external verification gaps.

Local adapter and Broker/ChatSession verification use the same versioned
contract-derived responses through production Req. External provider/consumer
paired verification remains unfinished. Context-window discovery and first-token
timing were not implemented by that correction. Context discovery is recorded below.
This mapping does not assert
complete part 3 or coordinated release readiness.

## Context-window discovery — preserved cycle-11 evidence

This correction implements only MODEL-METADATA-2026-10 section 1 (SHA-256
`a085da1c0d110f9d587a24ace6ac2854b653e1ac28905b3829d94d665b2c906e`).
The Foundry initiative brief was read and verified at SHA-256
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
Landed request fidelity, recovery and reasoning remain intact. First-token timing
is outside this correction; complete part 3 and coordinated release readiness
remain **partial**, including external contract verification below.

### Characterized boundary and executable identity

Before implementation, `Gateway` exposed model listing but no context discovery.
Ollama used configured `OLLAMA_HOST` for `/api/tags` and `/api/chat`; oMLX used
configured `OMLX_HOST` plus `/v1` and optional bearer authentication; OpenAI used
configured API routing/authentication for listing and completions. The registry's
exact entries and pattern fallback both served completion parameter selection.
The new metadata lookup uses exact entries only, preserving that fallback.

The first real-HTTP probe failed after reading Ollama's architecture capacity
because the result omitted model `num_ctx`. Adding separate `model_num_ctx` and
the pure clamping helper made the same probe pass. It asserts the exact
`POST /api/show` body, capacity/provenance, model limit and clamped caller limit.
The named probe is `Ollama discovery separates advertised and effective windows
through production Req` in
[test/mojentic/llm/context_window_wire_test.exs](test/mojentic/llm/context_window_wire_test.exs).

- Versioned executable set: **context-window-v1**;
  [contract](test/contracts/context_window_v1.json) SHA-256
  `cfeee4702c0dd3b18e02fbd0c8bad82ae58ee1ca7eadcfd21683479ba24f3dc4`.
- Tested base commit: `4ca97881bfe5249a3b4ebe0e3a640ec25e28cb1c` plus the
  uncommitted source/test snapshot identified by
  [manifest](test/contracts/context_window_v1.manifest.sha256), SHA-256
  `1c25185664b06c07e0d105a69e17ced6b5d238af615c2d3ff35ce2f58d138b76`.
  `sha256sum --check test/contracts/context_window_v1.manifest.sha256` passed.
- Verification: `scripts/verify-context-window-contract` prints the base revision
  and source/fixture hashes, then runs both
  [wire tests](test/mojentic/llm/context_window_wire_test.exs) and
  [consumer/helper tests](test/mojentic/llm/model_context_window_test.exs).
  **Exit 0: 194 tests, zero failures.** All cases run automatically in the
  existing `mix test --cover` gate and pinned CI test job.
- The scripted server's responses and Mox gateway doubles derive from this same
  contract through `Mojentic.TestSupport.ContextWindowContract`. The existing
  production `Mojentic.HTTP.ReqClient` is exercised, without mocking Req internals.
  The server now accepts bodyless GET requests as well as completion POSTs.
  Completion success frames reuse `request-fidelity-v1` rather than introducing
  independent completion doubles.

### Named conformance cases

| Requirement | Executable test names / declared cases |
| --- | --- |
| Exact authenticated oMLX selection and positive capacity | `context-window-v1 {adapter,consumer} omlx exact-selection exact wire and result`; also `exact-selection-without-api-key` |
| No model/field is not advertised | Same matrix: `omlx no-model`, `omlx no-field`, `ollama missing-info`, `ollama no-matching-key`, `ollama no-architecture-from-num-ctx` |
| Architecture-specific provenance and optional model limit | Same matrix: `ollama qwen3_5`, `ollama qwen4_exp`, `ollama model-num-ctx`, `ollama whitespace-num-ctx` |
| Reject invalid capacity and malformed bodies | Same matrix: `invalid-window-*`, `invalid-num-ctx-*`, `info-list`, `parameters-list`, `missing-data`, `data-object`, `bad-entry`, `missing-id`, `malformed-*` |
| Non-2xx status and transport causes | Same matrix: `http-401`, `http-404`, `http-418`; `context-window-v1 {Ollama,OMLX} {adapter,consumer} transport failure retains cause`; `non-200-success` verifies 201 acceptance |
| OpenAI exact registry, no HTTP or invented pattern capacity | `context-window-v1 registry {gpt-5.4,gpt-5.4-unknown,o1-custom,completely-unknown} performs no HTTP`; `registry metadata does not alter capability or pattern fallback`; `registry entries without a positive known capacity never invent a window` |
| Compatible old custom gateways | `legacy gateway without optional callback returns not advertised without dispatch`; the Mox gateway omits optional callbacks entirely |
| Pure effective-window precedence, clamping and unknowns | `context-window-v1 effective precedence and clamping 0` through `7`: caller overrides model, larger/smaller limits clamp, no limit uses capacity, unknown capacity remains nil even with caller limit; inputs remain unchanged |
| Contract-derived consumer doubles | `context-window-v1 consumer double {provider} {case} derives verified result` uses the same 53 provider rows, including errors |
| Existing configured lookup unchanged | `context-window-v1 {ollama,omlx,openai} preserves configured model lookup before and after discovery` asserts routes, authentication, empty GET bodies and returned names |
| Later completions unchanged | `context-window-v1 {Ollama,OMLX,OpenAI} discovery leaves subsequent {complete,object,legacy,events} request unchanged`: same model for discovery and completion, exact full JSON bodies and identical request bytes before/after discovery; config remains unchanged |

Legacy streaming in the last matrix consumes the first content event and closes
the stream. The terminal-event API is fully drained and its semantic terminal
result is compared. Existing request-fidelity/recovery suites continue to verify
fully drained maintained streams, continuations and admitted retries. This
correction does not change those paths or rebuild their contracts.

The helper reports an upper bound when neither caller nor model supplies
`num_ctx`: the server's `OLLAMA_CONTEXT_LENGTH` is not visible. Unknown advertised
capacity stays `nil`; discovery does not inject caller defaults, resize loaded
models, or alter ChatSession history trimming. Malformed discovery returns
`:invalid_response`; non-2xx returns `{:http_error, status}`; transport failures
retain the native cause under `{:request_failed, cause}`.

### Counterpart status and initiative finding

| Verification side | Tested identity | Command / result |
| --- | --- | --- |
| Local provider adapters | Base commit and manifest snapshot above | `scripts/verify-context-window-contract`: exit 0; production Req verifies all 53 provider rows, plus transport/registry/journey cases |
| Local metadata consumers | Same base and snapshot, same executable set | Same command: exit 0; compatible dispatch verifies the same rows, with contract-derived Mox doubles and old-callback compatibility |
| Actual oMLX/Ollama server producers | No tested external commit or server version | **Not run; missing paired verification** |
| Consumers in other repositories | No tested external commit | **Not run; missing paired verification** |

Initiative finding **mojentic-ex-context-window-v1-final-evidence-4ca97881**
records the contract/source hashes, both local sides' commands/results, and the
missing external verification for separate authorized coordination. It was
submitted with `foundry finding add` (exit 0), superseding the earlier snapshot
identities in `mojentic-ex-context-window-v1-counterpart-gap-4ca97881` and
`mojentic-ex-context-window-v1-same-model-counterpart-gap-4ca97881`.
No sibling repository was edited.
Actual providers and external consumers must verify this same versioned set;
schema agreement or independently authored mocks cannot close the gap. The
supplied TypeScript first-token regression finding and post-release typed-error
consumer assignments retain their separate scope. No release, Git finalization,
dependency change or runtime upgrade is authorized here.

### Context discovery quality results

Pinned Elixir **1.18.5**, Erlang/OTP **28.5.0.7**, selected by
`scripts/recovery-mix`; CI pins and PLT caching remain unchanged.

| Command | Result |
| --- | --- |
| `scripts/recovery-mix format --check-formatted` | Exit 0 |
| `scripts/recovery-mix compile --warnings-as-errors` | Exit 0, no project warnings |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | Exit 0, no project warnings |
| `scripts/recovery-mix credo --strict` | Exit 0, zero issues |
| `scripts/recovery-mix dialyzer` | Exit 0, zero errors/skips |
| `MIX_ENV=test scripts/recovery-mix dialyzer` | Exit 0, zero errors/skips |
| `scripts/recovery-mix test` | Exit 0; 22 doctests, 5,234 tests, zero failures, 19 existing integration exclusions |
| `scripts/recovery-mix test --cover` | Exit 0; 22 doctests, 5,234 tests, zero failures, 19 existing integration exclusions; **90.80%** coverage against 80% threshold; 616.4 seconds, below the 900-second gate limit |
| `scripts/recovery-mix deps.audit` | Exit 0, no vulnerabilities |
| `scripts/recovery-mix hex.audit` | Exit 0, no retired or security advisory packages |
| `scripts/recovery-mix sobelow --config` | Exit 0, no findings |
| `scripts/recovery-mix hex.outdated --all` | Exit 1, available upgrades; informational, nonblocking |
| `scripts/recovery-mix docs` | Exit 0; existing missing links to sibling release plan, README LICENSE and dependency usage-rules remain |
| `scripts/recovery-mix test test/mojentic/llm/context_window_wire_test.exs --only context_proof` | Exit 0; one selected proof, 129 excluded |

No `precommit` alias is defined. The existing CI pins and `priv/plts` caching
were preserved. Dependencies, versions, advisory suppressions and Git refs
remain unchanged; all source changes are uncommitted for Foundry review.

The standalone full suite passed before the test-only same-model assertion was
strengthened. The final focused contract and full coverage run include that
assertion; production code is identical across these runs. The full coverage
gate also passed before that strengthening (650.1 seconds, 90.80%). No new
integration exclusions or coverage suppressions were introduced.


## Cycle-12 correction: reject double-decoded Ollama metadata

This section supersedes the cycle-11 snapshot identity and quality results above
for context-window discovery. Tested source is preserved commit
`35013e921793710e344a708fdfea209248d4fd8e` plus the uncommitted candidate in
[test/contracts/context_window_v1.manifest.sha256](test/contracts/context_window_v1.manifest.sha256),
SHA-256 `407e4a0e7acec1c04dfe8d22b7e55a9722dc4e59182ce56c69f0cb81db070434`.
The initiative brief and binding MODEL-METADATA section 1 hashes above were read
and reverified against their coordinating copies. No external source was changed.

The additive **context-window-v1** executable set now has SHA-256
`9327502962112a020bafb46c6a677366df732f5a29cd44c92f17e8f632281395`.
All previous cases and supported optional/legacy callback behavior remain;
there are now 54 provider rows. Its new `ollama reject-json-string-object` row
serves `application/json` with a top-level JSON string containing
`{"model_info":{"qwen4_exp.context_length":262144}}` through a real TCP server.
Both `context-window-v1 adapter ollama reject-json-string-object exact wire and
result` and `context-window-v1 consumer ollama reject-json-string-object exact
wire and result` assert configured routing, exact `POST /api/show`, JSON content
type, no authorization and the model-only request body before asserting
`{:error, :invalid_response}`. The selected proof command is:

```sh
scripts/recovery-mix test test/mojentic/llm/context_window_wire_test.exs --only context_string_proof
```

Before the fix it exited **2**: both calls wrongly returned a 262144-token window
with `model_info.qwen4_exp.context_length` provenance. After the fix it exited
**0**, both selected tests passed (130 excluded). This is a behavioral regression
through production Req, with no mocked Req internals.

`ReqClient.ordinary_post/4` now disables Req body decoding and returns the raw
binary promised by `Mojentic.HTTP`. The gateway performs its existing single
JSON decode and shape validation. Retry, redirect, timeout, headers, request
bodies and the traced/stream implementations are unchanged. Contract-derived
`context-window-v1 POST {ordinary,no_retry,traced} preserves exact {case}
response bytes` checks seven response shapes in all three POST modes: a valid
object, the encoded object string, invalid JSON, array, null, number and string.
The existing object/provenance and malformed-shape cases still execute on both
local sides. Consumer doubles derive the new rejection from this same contract.

| Verification side | Tested identity | Command / result |
| --- | --- | --- |
| Local production adapters and HTTP boundary | Base commit plus manifest above | `scripts/verify-context-window-contract`: exit 0, 233 tests, zero failures |
| Local metadata consumers and pure helper | Same source identity and executable set | Same command: exit 0; direct and dispatch cases, contract-derived Mox doubles and compatible old callbacks |
| Actual Ollama/oMLX server producers | No external tested commit/version | Not run; missing verification of the updated shared executable set |
| External application consumers | No external tested commit | Not run; missing paired verification, retained for initiative coordination |

The verification script now includes shared POST byte conformance. Existing
same-model journeys compare identical completion requests before/after discovery
for ordinary/structured completion and both stream APIs; request-fidelity,
recovery, typed errors, native reasoning and cancellation remain in the full
repository suite. Schema checks and local doubles do not establish compatibility
with unverified external counterparts. Initiative coordination must assign and
run this exact updated set on both external sides and record their commits,
versions and results; that work remains unfinished. The prior cycle-11 finding
identifies an older executable snapshot and cannot certify this candidate.

Only the demonstrated response-decoding defect is corrected. No first-token,
recovery, dependency, runtime, version or release changes were made. Git
finalization belongs to Foundry; this candidate remains uncommitted.

### Cycle-12 quality results

Pinned Elixir 1.18.5 and OTP 28.5.0.7 remain unchanged, as do CI PLT caching
and the 80% coverage threshold. Final-candidate results:

| Command | Result |
| --- | --- |
| `scripts/recovery-mix format --check-formatted` | Exit 0 |
| `scripts/recovery-mix compile --warnings-as-errors` | Exit 0 |
| `MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | Exit 0 |
| `scripts/recovery-mix credo --strict` | Exit 0, zero issues |
| `scripts/recovery-mix test --cover` | Exit 0; 22 doctests, 5,258 tests, zero failures, 19 existing exclusions; 90.77% coverage, 634.5 seconds of test execution within the 900-second limit |
| `scripts/recovery-mix test` | Exit 0; 22 doctests, 5,258 tests, zero failures, 19 existing exclusions; 637.0 seconds |
| `scripts/recovery-mix dialyzer` | Exit 0; zero errors, skips or unnecessary skips |
| `MIX_ENV=test scripts/recovery-mix dialyzer` | Exit 0; zero errors, skips or unnecessary skips |
| `scripts/recovery-mix deps.audit` | Exit 0; no vulnerabilities |
| `scripts/recovery-mix hex.audit` | Exit 0; no retired or security advisory packages |
| `scripts/recovery-mix sobelow --config` | Exit 0; no findings under the existing configuration |
| `scripts/recovery-mix hex.outdated --all` | Exit 1; available updates, informational and nonblocking |
| `scripts/recovery-mix docs` | Exit 0; existing missing-link warnings only |
| `sha256sum --check test/contracts/context_window_v1.manifest.sha256` | Exit 0; all candidate source/contract/test hashes match |

No `precommit` alias is defined. Sobelow retains its pre-existing
`Traversal.FileModule` exclusion; no exclusions or advisory suppressions were
added. ExDoc still reports the existing missing `LICENSE`, sibling
`../RELEASE-3.0.0.md` and dependency usage-rules links. No security finding
requires a dependency change. Gate evidence and behavioral failure/pass logs are
retained by Foundry for review; they are execution scratch, not package sources.


## Model metadata section 2: client first-token timing (October 17 correction)

This section supersedes earlier cycle-specific timing deferrals. The coordinated
3.0.0 release hold remains. Context-window discovery, effective-window clamping,
registry fallback, request fidelity and native reasoning retain their existing
contracts and implementation. No dependency/runtime/version or Git-ref changes
are part of this correction.

### Binding sources and executable identities

- Initiative brief: verified SHA-256
  `ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
- `mojentic-unify/MODEL-METADATA-2026-10.md` section 2, source checkout
  `ef9339c6a9682ed5f060bd690b738f6b8eea1d2d`, verified SHA-256
  `d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c`.
  This includes Stacey’s October 17 thinking/content/tool precedence, one clock
  across retries, and a fresh clock for each tool continuation.
- Owner-designated **ts-stream-first-token-v1**, TypeScript source
  `b8db5d59c02297e39335ba1deed83fa04e1b8f11`, executable-file SHA-256
  `e94d4f53928b3ea519eceedcb0f7e7a41ae2eb5da52076369d92374108b3d2a8`.
- Additive **ts-stream-first-token-v2**, TypeScript source
  `54171796a2b02c0f0170d0758d2e3c693ad027c9`, executable-file SHA-256
  `9b64e037af8ee375a6344b94f4f66992f867357a32b8db360042a8eff4f12eca`.
  Both exact executable sources are retained under `test/contracts/reference/`;
  the required gates verify their hashes. These files are provenance references,
  not a claim that Jest ran in this Elixir worktree.
- Local **ex-stream-first-token-v1**:
  `test/contracts/stream_first_token_v1.json`, consumed by
  `test/support/first_token_contract.ex` and
  `test/mojentic/llm/first_token_wire_test.exs`. The fixture identifies shared
  reference cases and controlled dispatch/frame/capture milestones.
  `scripts/verify-first-token-contract` checks both frozen references, prints
  HEAD and source/test/fixture hashes, and runs the executable local matrix.

Tested Elixir source is base `df29a1c36f6b4b172b3ff352d40201d6583a9890` plus
this uncommitted correction. Exact local fixture/test hashes and gate results are recorded below. Foundry owns Git finalization.

### Characterized boundary and implementation

`ReqClient.post_stream/4` constructs a cold stream. Enumeration enters
`WireTrace`, starts the measurement at authorized HTTP dispatch, and advances
one Req/Finch response continuation. Wire bytes form complete SSE/NDJSON frames
before the optional capture callback. `StreamTiming` records the first frame’s
kind and latency atomically, independently of delivery and capture acceptance.
One small numeric reference survives a cancelled/killed capture worker; it
contains no request or response payload. No new process or storage is needed.

Recovery shares that reference across sequential admitted attempts and decorates
the final success/error after the policy returns. Recovery lifecycle/history
snapshots retain their existing policy/provider fields; terminal-only client
measurements do not retroactively rewrite those snapshots. Existing snapshot
assertions remove only the three additive client fields with `StreamEvidence`;
the new contract asserts the full terminal timing separately. Cancellation,
admission decisions, original causes, IDs, bounded history and replay barriers
remain covered by the existing real-wire suites.

Recovery-disabled adapters retain their parsers. Legacy streams now expose
`{:completed, evidence}` per successful logical completion. The Ollama legacy
path retains one HTTP continuation instead of re-enumerating the cold request;
permissive legacy finish handling remains available, with the reported finish
reason retained. Strict terminal validation remains in event/recovery APIs.
Supported legacy EOF and omitted-finish-reason parsing remain available. Broker forwards
each turn’s evidence, then starts a new completion for a tool continuation.
ChatSession forwards evidence while accumulating only visible text and refuses
successful finalization after a stream failure.

### Named executable checks and reference case mapping

All local cases use production `ReqClient`, loopback TCP and the existing
`ScriptedCompletionServer` mechanism. Only the monotonic clock boundary is
controlled through Mox and a supervised Agent. No completion result, provider
parser, Req function or recovery result is mocked.

| Contract requirement / shared case | Local named test family in `first_token_wire_test.exs` |
| --- | --- |
| v1 content-first, thinking-first, tool-argument-first | `<provider> <route> <case> without recovery measures the production dispatch`; same cases through delayed capture |
| v1 keepalives, empty deltas and names | `empty`, `empty-content`, `tool-name-only`, `empty-tool-arguments`; first-token pair absent, duration present |
| October 17 within-frame precedence | `thinking-content-tool-precedence`, `content-tool-precedence`; later frames cannot replace the first kind |
| v2 split-frame capture regressions | `<provider> <route> <case> split capture delayed/rejected/cancelled retains observation and terminal timing` |
| v2 legacy `function_call` fragments | `legacy-arguments`, `legacy-name-only`, `empty-legacy-arguments`; same capture matrix |
| Exact first-token and total durations | Construction 10, dispatch 100, partial frame 110, complete frame 125, capture/terminal 180; assertions are 25/80 ms, independent of clock-call counts |
| No uncaptured output | Capture matrix observes actual emitted semantic events before release, then asserts no delivery on reject/cancel and exactly one terminal event |
| Preserve provider metrics | Shared terminals retain Ollama `total_duration: 900`, `prompt_eval_duration: 200`, and compatible usage `time_to_first_token: 0.7`, `total_tokens: 5` |
| One clock across retries | `<provider> <route> admitted retry spans one dispatch clock and repeats exact wire request`; 503, admitted retry, 25/80 ms, identical ordered request bytes, shared logical ID |
| New clock for each tool continuation | `<provider> <route> tool continuation starts a fresh clock and executes once`; first turn 25/80 ms, continuation 25/50 ms, distinct logical IDs, exact retained history and JSON-encoded tool result |
| HTTP errors without tokens | `<provider> recovery <policy> HTTP rejection has duration without a first token`; frame-shaped error bodies never count as tokens |
| Failure after the first token | `<provider> <route> recovery <policy> retains first-token timing on disconnect without replay`; real premature socket closure, terminal 25/80 ms |
| Legacy arguments prevent replay | `<provider> <mode> legacy argument observation prevents resend after disconnect`; argument fragment observed before a complete call, no delivery/admission/resend |
| Default public session path | `<provider> default session forwards timing and finalizes successful history`; only visible assistant content enters history |
| Supported Ollama EOF framing | `Ollama <route> split final frame without newline through <outcome> end capture`; direct/Broker event paths without recovery also retain timing and provider metrics |
| Version/provenance integrity | `frozen v1 and additive v2 executable references retain their source identities` |

Providers are OpenAI, Ollama and oMLX. Routes are direct event/legacy adapters,
Broker event/legacy APIs and ChatSession. Requests assert configured routing,
authentication, exact decoded bodies and ordered wire requests. Terminal checks
assert cardinality and iterator exhaustion, not just request counts.

The proof-first split-frame/rejected-capture test failed on the original
production source with missing metadata (exit 2), then passed with 25 ms
thinking-first latency and 80 ms failure duration (exit 0). No semantic output
or resend occurred. Foundry’s behavioral proof and complete logs are archived
separately from repository deliverables.

The additional supported-Ollama EOF characterization found missing first-token
fields when the final valid JSON frame had no newline. The isolated real-HTTP
probe failed with duration 80 ms but no first-token pair (exit 2). After observing
the trailing frame at confirmed EOF before response-end capture, the same probe
passed with thinking-first 25 ms and duration 80 ms (exit 0), without delivering
uncaptured output. The local fixture now also carries `eof_frame`, with delayed,
rejected and cancelled end-capture cases across direct adapters, Broker and
ChatSession, and recovery-disabled event cases. This preserves the parser’s
existing EOF compatibility; it does not change finish validation or recovery
policy. The isolated source-load probe leaves another running test VM untouched;
final gates below use normal Mix compilation.

The dense timing matrix uses the existing TCP harness with a 1 ms accept poll;
older fixtures retain their existing 50 ms default. This removes idle test-control
waits without changing response bytes, virtual clock milestones, or production
HTTP dispatch/capture paths.

### External paired verification: unfinished

The local matrix maps the same identified v1/v2 behaviors into Elixir’s existing
executable mechanism. Frozen source hashes and local real-HTTP checks establish
traceability and local behavior; they do not establish cross-repository paired
verification. There are no independently authored completion mocks presented as
paired evidence.

The TypeScript record at `54171796a2b02c0f0170d0758d2e3c693ad027c9` reports
`npm test -- --runInBand src/llm/first-token-http.test.ts` passing 218/218 for v2.
That is inspected historical evidence, not a fresh verification run by this
correction. TypeScript and any other producer/consumer must verify the same
identified shared cases against this Elixir source before initiative coordination
can mark the cross-repository work complete. No external repository was changed
or finalized. Bedrock and bedrock-workshop consumer verification remains pending
publication and coordinator authorization, as recorded in the initiative brief.

### Final local verification

Runtime: Elixir **1.18.5**, OTP **28.5.0.7**, selected and asserted by the unchanged `scripts/recovery-mix`. No `precommit` alias is defined. The complete discovered project gates and applicable additional checks ran through Foundry capture.

| Command | Exit | Actual result |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | Passed. |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | Passed with warnings treated as errors. |
| `env MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | Passed in test environment with warnings treated as errors. |
| `scripts/recovery-mix credo --strict` | 0 | Passed; zero findings. |
| `scripts/recovery-mix test test/mojentic/llm/first_token_wire_test.exs --only first_token_proof` | 0 | One selected real-HTTP split-frame proof passed. |
| `scripts/recovery-mix test test/mojentic/llm/first_token_wire_test.exs --only first_token_eof_proof` | 0 | One selected real-HTTP EOF/end-capture proof passed. |
| `scripts/verify-first-token-contract` | 0 | 804 tests passed; frozen v1/v2 identities verified. |
| `scripts/recovery-mix test` | 0 | 22 doctests, 6062 tests, zero failures; 19 existing integration exclusions. |
| `scripts/recovery-mix test --cover` | 0 | Same full suite passed; 91.12% coverage, above the configured 80% threshold. |
| `scripts/recovery-mix dialyzer` | 0 | Passed; no type errors. Existing CI PLT cache and ignored priv/plts paths retained. |
| `scripts/recovery-mix deps.audit` | 0 | Passed; no vulnerabilities found. |
| `scripts/recovery-mix hex.audit` | 0 | Passed; no retired or security-advisory packages found. |
| `scripts/recovery-mix sobelow --config` | 0 | Passed. Non-Phoenix project; existing router notice/lockfile syntax diagnostics remain. |
| `scripts/recovery-mix hex.outdated --all` | 1 | Available upgrades reported; nonblocking visibility check. No dependency changes or advisory suppressions. |
| `scripts/recovery-mix docs` | 0 | Generated successfully. Existing missing links remain for README LICENSE and AGENTS parent release/dependency rules; no docs gate failure. |

The final source passed both plain and coverage suites. Earlier full runs exposed old terminal-shape expectations and the characterized Ollama duplicate-request expectation; those assertions now retain their original content, wire, timeout, privacy and policy checks while checking the new evidence. An unrelated pre-existing realtime test using a fixed 200 ms sleep failed once during the initial PLT build; final sequential gate runs passed without changing that test.

The exact local portable contract is **ex-stream-first-token-v1**, SHA-256 `fddd71c8e0062c489588b2e15df749e934cf9d9412d05b4ee08eb52673425a6c`. A paired external run must adopt/verify this same identified set and report its own tested source identity and results. The inspected TypeScript historical result is not fresh paired verification. These source/test/fixture hashes identify the tested uncommitted Elixir revision in addition to base HEAD `df29a1c36f6b4b172b3ff352d40201d6583a9890`:

```text
fddd71c8e0062c489588b2e15df749e934cf9d9412d05b4ee08eb52673425a6c  test/contracts/stream_first_token_v1.json
94d4b78c2d81ec2dbd038cde47fa6a81f01e33b96861e1d3d94e294ab5c6a7ce  test/support/first_token_contract.ex
8252526fb78a59e214d80916ebbd78d3305ebc8df2a43d1cfbce4ac8722ffd9a  test/mojentic/llm/first_token_wire_test.exs
2d019b968bf1a0ab0fe22966ea84da0a850b3e610b488185f61399063d895859  lib/mojentic/llm/stream_timing.ex
c80fde0b70765392f78deb0c05be5e3cf3d7e54e06c1f5a35f81e00c3731b786  lib/mojentic/llm/monotonic_clock.ex
e6d038a33928a6436b5398a6a6d251502334c5f2287eeca135779dd259b0dbbc  lib/mojentic/llm/stream_recovery.ex
2027ca4b43e19313bb3c40be55e91e72622f15b6870a72794a6863db17b33d01  lib/mojentic/llm/completion_error.ex
4424d8d60fbebd9f4481aed62f6fe4b95897527b2ea1973bd946353d19c94f86  lib/mojentic/llm/broker.ex
ef732a7d9a7ba1e7b184258ce4249566a0d4187e2bb60f997a8bb5daab27dc8d  lib/mojentic/llm/chat_session.ex
780cad057878d7d2221fbd117182fc50f46c8fc123bc21b185fa9c96e7dcb969  lib/mojentic/llm/gateways/openai.ex
4fe21b95aa072a6ca60a6605bec88c93fbea4e96234afd7f491b809fa246b692  lib/mojentic/llm/gateways/ollama.ex
02fad11d1d7d8efa060122d05d8789629bcefdc5f8fd727c41948e4320313460  lib/mojentic/llm/gateways/omlx.ex
70f985636c0675fce8015d2dc60ff3e52591bf7a86c739b721432e775e34a265  lib/mojentic/llm/gateways/openai_legacy_stream.ex
6cd62d48590d22d341729128a1dd110404167d7f20c207eecf15e40726043f03  lib/mojentic/http/req_client.ex
fc0b4055ab5e35f5338922e575c734b779f79a07902c4cfb14b7441a3f7b7885  lib/mojentic/http/wire_trace.ex
05ec61d00bcd1bb3e240bcc55605dcd45d53dfd0efcb38b5bfd728ec752d7b6d  lib/mojentic/http/received_evidence.ex
5eef2bbcbc63b5a69d818d1bc1fb1ec29519da2834565d614a9000c6e466ecad  test/support/scripted_completion_server.ex
d77cb743856a8b46ced5c96658a7945fb497440c164c2b2ede88c25b284f08b6  test/support/stream_evidence.ex
27e97d2a5beb44b1482b04a10e408412cafe68177704870571f11eb9a1817fce  test/test_helper.exs
1280e3fdcc50846677f8d5bca6fa9bfa71a140472c90b6627f9fd78db65cfdb3  mix.lock
```

Both behavioral proofs have validated JSON, actual rejecting exit 2 / corrected exit 0, and complete existing logs. All changes remain uncommitted for Foundry review. No version bump, tag, publish, push, merge, rebase or ref modification occurred. External paired verification and the coordinated release remain unfinished.
