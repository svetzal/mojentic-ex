# 3.0.0 recovery conformance (partial)

This partial record covers the October 12 **Retry-After dates** correction, the
**Admission without a hook** guarantee and preservation of the landed
**Admission without a decision** amendment.
Admission sections below preserve earlier execution evidence; the date section
records the current rollover correction. It does not establish full 3.0.0 readiness. The coordinated release hold remains.

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
