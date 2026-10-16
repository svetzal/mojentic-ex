# 3.0.0 admission conformance (partial)

This record covers only the October 12 **Admission without a decision** amendment.
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

Local executable admission set: `admission-without-decision-v1`, implemented in
`test/mojentic/llm/admission_wire_test.exs`, SHA-256
`3d2ba168371aaf96758009ef8b5d0d71c2f2e2c799f26c93d1f125e42c850cd3`.
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

The first real-boundary probe, event-stream admission raising with a sentinel,
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
`Recovery.work/3`, backoff, CompletionRequest and StreamRecovery were not changed.

## Verification and coordination gaps

Tested base commit: `72c762cc25da06f6ef169d0756a001a81b3e3d3d`, plus the uncommitted
admission correction. Production file `lib/mojentic/llm/recovery.ex` has SHA-256
`2069a4a0f692d0c43ea0b5b422a42ce37a1ddc790a8f126515410128944a312c`.
Foundry owns finalization; no landed commit is claimed.
Runtime remains the CI-pinned Elixir 1.18.5 / OTP 28.5.0.7. Commands below use
`scripts/recovery-mix` and are captured by Foundry in execution evidence.

All discovered `.hone-gates.json` entries were executed. Results for the final
source and executable test set (all commands prefixed with `scripts/recovery-mix`):

| Command | Exit | Outcome |
| --- | --- | --- |
| `format --check-formatted` | 0 | Formatted |
| `compile --warnings-as-errors` | 0 | Development compile passed |
| `MIX_ENV=test ... compile --warnings-as-errors` | 0 | Test compile passed |
| `credo --strict` | 0 | Zero issues after splitting the assertion helper |
| `test test/mojentic/llm/admission_wire_test.exs` | 0 | 330 cases, zero failures |
| `test` | 0 | 22 doctests, 3,479 tests, zero failures; 19 default integration exclusions |
| `test --cover` | 0 | 22 doctests, 3,479 tests, zero failures; 90.21% coverage |
| `dialyzer` | 0 | Zero errors, zero skipped warnings |
| `MIX_ENV=test ... dialyzer` | 0 | Zero errors, zero skipped warnings |
| `deps.audit` | 0 | No vulnerabilities reported; freshness caveat below |
| `sobelow --config` | 0 | Passed under unchanged configuration |
| `hex.audit` | 0 | No retired or advisory packages reported |
| `hex.outdated --all` | 1 | Informational available upgrades |
| `docs` | 0 | Built; existing link warnings below |

An earlier full coverage run after the production correction also passed:
22 doctests, 3,479 tests, zero failures, 19 default integration exclusions;
90.21% coverage against the unchanged 80% floor. The final coverage rerun also passed with the same totals and covers the
completed assertion-helper refactor and prior-conversation wire assertions.

An overlapping plain-suite run exited 2 with one existing Realtime test failure:
`function_call items are executed and outputs submitted` observed no output after
its fixed `Process.sleep(200)` wait. An unchanged focused rerun,
`test test/mojentic/realtime/session_test.exs:338`, exited 0. This is consistent
with timing sensitivity under concurrent suite/PLT work; no Realtime code or
assertion was changed or suppressed. The isolated full rerun is recorded above.

Security validation: configured MixAudit and Hex audit both exit 0 (no findings).
MixAudit's attempted refresh cannot write the external read-only `FETCH_HEAD`;
its installed advisory revision `935abf7410a2bbb18e12579dee6e31267c3ed244`
was independently checked equal to upstream `main` with `git ls-remote`.
Configured Sobelow exits 0; its existing configuration excludes
`Traversal.FileModule`. No suppression or configuration was changed, and this
result does not claim an unfiltered security audit. `hex.outdated --all` exits 1
for available upgrades (informational); no dependencies were changed.
`docs` exits 0 with existing LICENSE and igniter usage-rule link warnings.

**Missing paired verification:** no shared versioned executable producer/consumer
contract set was found for this amendment. No other repository was changed or
verified. Consumer commits, supported old/new version cases, and both sides'
verification commands/results are therefore unavailable. Coordination must provide
that set (including errors, optional fields and semantic behavior), derive doubles
from it, and run it in both repositories' required gates before compatibility is
claimed. The local suite is not a substitute for that work or a full user journey.

Remaining 3.0.0 coverage gaps include the other recovery amendments, native
reasoning, model metadata/request fidelity, and the rest of the initiative's
per-port readiness requirements. None is implemented or certified by this task.
