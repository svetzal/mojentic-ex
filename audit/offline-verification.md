# Offline verification

## Tested revision and reconciliation

Both source and fresh local-Hex consumers test base revision
`af9ca54b9ffdad589289a52f22828a8c19537330` plus the uncommitted correction
identified below. The preserved migration and retry-cancellation correction are
retained. Trunk release commit `38875faede2679690483d7b8ec2f70fdeefafaaa` is
already an ancestor: `mix.exs` version 3.0.0 and CHANGELOG match trunk exactly.
No merge or ref changes were needed. Production `lib` tree
`b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`, dependencies, runtime pins,
public APIs and the 80% coverage floor are unchanged. Git finalization belongs
to Foundry; all correction changes remain uncommitted.

The tested source execution tree SHA-256 is `6ebabd1eb7a3ba6fb80771756ffcf59fcef39ad59487a96d85516c3998fa5a36`.
It hashes sorted `SHA-256  relative-path\n` records for every file under
`lib/`, `test/`, `scripts/`, `.github/workflows/`, plus `mix.exs`, `mix.lock`,
`.formatter.exs` and `.hone-gates.json`. Audit prose is outside that identity.

## Shared executable contracts

The shared set is **ex-readiness-v1**. Source public-API consumers/provider
verification and the fresh extracted Hex-payload consumer/provider verification
run the same manifest-selected cases, including realtime interruption. Extracted
provider inputs and copied consumer inputs are verified against the same manifest.
The fresh consumer compiles the actual payload and verifies ReqClient's code path
inside its own build. Local dependency sources/builds are reused, excluding
Mojentic. HEX_OFFLINE=1 prevents registry access; no publish or deps.get occurs.

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `80141cf30a543b798d5818c29c1e8af9bd4d027345fbe312f064f23a8a5b8faf` |
| `test/contracts/readiness_v1.manifest.sha256` | `4663dde1adb57926480dce4f01ab669b9723b7da88714966d7dc1320419630e2` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `88962afa7cb210f63448c3ebb672ae677ab1152c1e7969a11153d6478aed585a` |

Tested Hex artifact: local `mojentic.tar`, package version **3.0.0**, SHA-256
`40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`. The payload is built locally and never published.

## Interrupted-turn proof

`test/mojentic/realtime/session_test.exs`:
**interrupted turn with :drop policy discards tool outputs** drives Session's
public API and the in-process FakeTransport. It correlates response `r2`, call
`c3`, arguments Carol and the successful greeting result. Tool completion and
normal worker DOWN alone cannot establish batch processing. A receive trace
observes the exact batch result at Session; a subsequent public subscribe reply
establishes handler completion before inspecting subscriber events and transport
payloads. No internal state is asserted and no result is injected into Session.
The test requires absent r2/c3 submission and absent c3 function_call_output.

The temporary rejecting probe changes on_interrupt to submit_completed_only and
holds the separate batch task after the real runner returns. The test releases
that task only after observing tool_call_completed(c3) and the monitored worker's
normal exit. It then observes actual batch receipt and public call completion.
The drop assertion fails with the exact transport payload:

```json
{"type":"conversation.item.create","item":{"type":"function_call_output","call_id":"c3","output":"{\"greeting\":\"Hello, Carol!\"}"}}
```

Probe command: `scripts/recovery-mix test test/mojentic/realtime/session_test.exs:427`.
Rejecting delayed submit_completed_only probe exits **2**; the same delayed probe
with drop exits **0**. After removing temporary instrumentation, the corrected
focused test exits **0**. The recorded behavioral proof's JSON shape, string and
integer fields, actual exit codes and log existence were validated. Temporary
production instrumentation is absent from the final tree. No socket, server,
service/registry call, real sleep or wall-clock threshold is used.

## Final gates

All nine `.hone-gates.json` commands exited zero. Runtime: pinned Elixir 1.18.5 /
OTP 28.5.0.7, MIX_ENV=test, HEX_OFFLINE=1. Hashes identify complete stdout captures
archived with execution evidence, without depending on disposable checkout paths.

| Command | Exit | Stdout SHA-256 |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `9f4a5bd19656cbe835d3c7801d11a7b3e9b7c76bf96e18e0a6c39598923d9708` |
| `scripts/recovery-mix test --cover` | 0 | `2906b7e53f9f32c58b854d3d12d0c5ec32d71fde00c05aaa58abf51c10b14fd3` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-first-token-contract` | 0 | `0ec57eb365e76160a9709cc9bb357ba890a86e1579115ff871494971c12ebabd` |
| `scripts/verify-readiness-contract` | 0 | `8768d8ad8092472b52a481be05fe5da586b1d3294d029c7d4e0c8d833068db58` |
| `scripts/verify-packaged-first-token` | 0 | `46ba060de8638ffdc435d3039b57edc467de4ecf4879904c7091e45f0fa560be` |

test:

```text
Finished in 177.6 seconds (105.2s async, 72.4s sync)
22 doctests, 6084 tests, 0 failures
    91.45% | Total
```

first-token-contract:

```text
Finished in 38.5 seconds (0.00s async, 38.5s sync)
864 tests, 0 failures
```

readiness-contract:

```text
Finished in 164.5 seconds (92.1s async, 72.4s sync)
5395 tests, 0 failures
```

packaged-first-token:

```text
Finished in 159.0 seconds (87.1s async, 71.9s sync)
5395 tests, 0 failures
```

## Preserved behavior and scope

The offline Req migration retains production request preparation, dispatch,
observation and cleanup through the in-process adapter. Exact prepared requests,
errors, optional fields, cancellation and lifecycle identities remain exercised.
The retry-worker cancellation case still selects the actual blocked worker,
installs its monitor before cancellation and requires DOWN reason killed;
noproc is not accepted. First-token disconnect fixtures release data and await
public delivery before injecting EOF; injected clocks establish exact timing.
Tokenizer operations use the committed byte-tokenizer fixture without model
registry access. No live infrastructure is required.

The offline surface scanner passes as part of source readiness verification.
[Decision mapping](../test/contracts/DECISIONS.md),
[3.0.0 conformance](../CONFORMANCE-3.0.0.md) and
[recovery conformance](../RECOVERY-CONFORMANCE.md) retain named executable cases
for binding parts 1–3 and parts 4–5 applicability. Frozen root contracts and
TypeScript provenance remain as recorded in the conformance map. This is library
self-validation, with no changed running service boundary or claim of external
provider verification. Dependents verify when adopting a published version.

## Security and supplementary checks

MixAudit scans the complete existing advisory snapshot
`83be990cdd1105386d97f133b041215e97a58a61` without filtering or suppression.
A read-only execution wrapper refuses its git synchronization so it cannot
write outside this worktree or change refs. This verifies the local snapshot,
not a newly fetched advisory database. Sobelow uses its unchanged configuration.

Supplementary final-tree checks:

| Command | Environment | Exit | Stdout SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix test test/mojentic/realtime/session_test.exs:427` | `test` | 0 | `a9fa2aaa731761947a8d0f9b2913042568b59147fbda2437a7d602bb33dc2d69` |
| `scripts/recovery-mix dialyzer` | `test` | 0 | `0118ef81e344612313be85b1f962049fe6b88c5f0fcfe92d32093d2773159126` |
| `scripts/recovery-mix hex.audit` | `test` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` |
| `scripts/recovery-mix hex.outdated --all` | `test` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` |
| `scripts/recovery-mix docs` | `dev` | 0 | `0583ac826ef2f3f6e0588417c85a8f43be2fa0eabad0d8b4c18586e78e476967` |

Dialyzer reports zero errors, skips or unnecessary skips. Hex audit reports no
retired or security-advisory packages. Hex outdated exits 1 for available updates;
this is informational and no dependency is changed. Documentation builds
successfully with existing missing-link warnings for `LICENSE`,
`../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`. Strict Credo reports no
issues; compilation with warnings-as-errors passes.
