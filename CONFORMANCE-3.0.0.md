# 3.0.0 recovery conformance (partial)

This partial record covers the October 12 **Retry-After dates** correction, the
**Admission without a hook** guarantee and preservation of the landed
**Admission without a decision** amendment.
It does not establish full 3.0.0 readiness. The coordinated release hold remains.

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
during the admission corrections. The date correction below changes only
CompletionRequest date normalization.

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


## Retry-After dates executable set (2026-10-16)

Local executable set **`retry-after-dates-v1`** reuses the existing scripted TCP
provider and production Req boundary. Run `scripts/verify-retry-after-dates-contract`;
it prints the file hashes below, then executes both test files. The unchanged
`.hone-gates.json` `test --cover` gate also executes the entire set.

| Executable source | SHA-256 |
| --- | --- |
| `test/mojentic/llm/retry_after_dates_wire_test.exs` | `881ec59dd02a300338c48e490bc259d606a7c146d1c39a8b69baa45e75ffdfaa` |
| `test/mojentic/llm/recovery_wire_test.exs` | `b707be8df4b68b4cac10c3f2de1837443947df7a4417f94b3cf425a3a77c3f00` |
| `test/support/scripted_completion_server.ex` | `d03a3cf93eb25350bd8bf2387e70fbf7786e86e663809f55dfd7180f6e782e07` |

Binding source remains the October 12 root amendment and SHA-256 identified
above; its hash was checked again for this correction. The initiative brief hash
also matched. Tested Elixir revision: `2829348ec1d6c5592b594141102c9574f051a9e4`
plus this uncommitted correction. CompletionRequest source SHA-256:
`30365303f94f1b846c408f09befbcf9083921463a801d2e76b4844568ea91171`.
No package, dependency or runtime version changed. Elixir 1.18.5 and OTP
28.5.0.7 remain selected by `scripts/recovery-mix` and pinned in CI.

### Real-boundary characterization and named checks

The recipient format requirement is [RFC 9110 section 5.6.7](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.7).
The installed Req 0.7.5 `Req.Utils.parse_http_date/1` accepts IMF-fixdate and
rejects RFC 850 and asctime. Before expanding fixtures or documentation,
`RFC 850 structured recovery honors the date through real Req` failed through
OpenAI structured completion: `retry_after` was `:invalid` instead of
`{:http_date, "2026-01-01T00:00:03Z"}` (exit **2**). After the source correction,
the same command passed (exit **0**):

```
scripts/recovery-mix test test/mojentic/llm/retry_after_dates_wire_test.exs
```

The probe checks a 3,000 ms scheduled delay, exact identical structured inference
requests, distinct attempt IDs under one logical request, terminal history and
an independently observed absence of a third request. The implementation
normalizes RFC 850 and asctime to IMF-fixdate before using Req's existing
calendar/time/weekday validation. Two-digit RFC 850 years more than 50 years
ahead resolve to the most recent past year with those final digits. The policy,
admission logic and delay-seconds parser are unchanged.

The new file contains that probe and 570 generated named checks:

- `<gateway> <entrypoint> <form> <scenario> normalizes metadata and enforces wire recovery limits`:
  OpenAI, Ollama and oMLX; `complete`, `object`, `events`, `legacy`, `broker`,
  `broker_object`, `broker_events`, `broker_legacy`, `session`, `session_stream`;
  IMF-fixdate, RFC 850 and asctime; future, past, delay-ceiling refusal and
  recovery-budget refusal. Each date uses a deterministic observed wall clock.
- `<gateway> <entrypoint> <case> preserves existing Retry-After behavior through Req`:
  delay seconds, absent headers, invalid text/calendar/weekday/time and an RFC 850
  date resolving to the previous century.

Every generated case observes the production scheduler's sleeper and backoff
metadata, exact recorded request bytes and trace IDs, route/model/conversation,
structured schema and stream flag, safe normalized metadata in errors, histories,
admission contexts and lifecycle events. It asserts unique attempt IDs, one
logical request, terminal history and an independent negative wire observation.
Refusal cases observe no sleeper call and no resend. Streaming session failures
cannot finalize successfully; prior history remains intact. Provider, credential
and input sentinels never enter safe metadata. No Recovery results are mocked.

The existing ordinary/structured success cases
`<gateway> <operation> real Req Retry-After <header> respects observed wall clock and policy minimum`
now include RFC 850 and asctime alongside IMF-fixdate, delay seconds, past dates
and invalid text. They verify successful completion, the scheduled delay and
unchanged full payload. The entire suite preserves both admission guarantees and
explicit decisions.

### Date verification results

Commands use `scripts/recovery-mix` under the existing pinned runtime unless a
different executable is named. All `.hone-gates.json` entries were executed.
The release hold and Foundry finalization rules remain in force.

| Command | Exit | Result |
| --- | --- | --- |
| `format --check-formatted` | 0 | Passed |
| `compile --warnings-as-errors` | 0 | Passed |
| `MIX_ENV=test ... compile --warnings-as-errors` | 0 | Passed |
| `credo --strict` | 0 | Zero issues after splitting the oversized test helper |
| `scripts/verify-retry-after-dates-contract` | 0 | 1,213 tests, zero failures |
| `test` | 0 | 22 doctests, 4,183 tests, zero failures, 19 configured integration exclusions |
| `test --cover` | 0 | 22 doctests, 4,183 tests, zero failures, 19 configured integration exclusions; 90.25% coverage against the unchanged 80% floor |
| `dialyzer` | 0 | Zero errors and zero skipped warnings |
| `MIX_ENV=test ... dialyzer` | 0 | Zero errors and zero skipped warnings |
| `deps.audit` | 0 | No vulnerabilities reported; cache freshness independently checked |
| `hex.audit` | 0 | No retired or advisory packages reported |
| `sobelow --config` | 0 | Passed with the existing configuration |
| `hex.outdated --all` | 1 | Informational available upgrades; dependencies unchanged |
| `docs` | 0 | Built; existing broken-link warnings remain |

MixAudit's refresh attempt cannot write its read-only external `FETCH_HEAD`.
The installed advisory revision `935abf7410a2bbb18e12579dee6e31267c3ed244`
was independently verified equal to upstream `main` via `git ls-remote` in this
execution. No advisory suppression was added. Sobelow retains the existing
`Traversal.FileModule` exclusion. ExDoc warnings concern README `LICENSE`, the
absent sibling `../RELEASE-3.0.0.md` in this isolated worktree and the existing
`deps/igniter/usage-rules.md` link. No gate was weakened.

### Paired verification remains unfinished

`retry-after-dates-v1` is a **local** executable-set identity, not a jointly
verified contract. Local consumer-side verification exercises gateway, Broker
and ChatSession requirements using a scripted provider. Real provider verification
against the same executable set is **missing**. No other repository was changed
or tested. Paired consumer/provider commits, supported old/new version semantics,
optional-field cases and both verification commands/results remain unavailable.
Coordination must supply a shared versioned set, derive doubles from that verified
set and run verification in both repositories' required gates. This task does
not claim cross-repository compatibility, full 3.0.0 conformance or release readiness.
