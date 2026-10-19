# Offline verification

## Tested revision and reconciliation

Both source and fresh local-Hex consumers test base revision
`5d7698826b32f7bc1bd48e1e411ecddb6336f79d` plus the uncommitted scanner correction
identified below. The preserved migration and retry-cancellation correction are
retained. Trunk release commit `38875faede2679690483d7b8ec2f70fdeefafaaa` is
already an ancestor: `mix.exs` version 3.0.0 and CHANGELOG match trunk exactly.
No merge or ref changes were needed. Production `lib` tree
`b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`, dependencies, runtime pins,
public APIs and the 80% coverage floor are unchanged. Git finalization belongs
to Foundry; all correction changes remain uncommitted.

The tested source execution tree SHA-256 is `b44077f3424be20da2405a0b6c637343de1eb8a19a314f30de9b9db7b95b5bd4`.
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
| `test/contracts/readiness_v1.manifest.sha256` | `2a94ea8dc8cf3d5c4add59b3142780db4800634b0f4a9ac7a1c8c410bbbd7768` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `88962afa7cb210f63448c3ebb672ae677ab1152c1e7969a11153d6478aed585a` |

Tested Hex artifact: local `mojentic.tar`, package version **3.0.0**, SHA-256
`40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`. The payload is built locally and never published.

## Scanner declaration proof

The scanner's socket-server and model-loading alternatives now spell the same
matches with character classes: `TCP[S]erver`, `HTTP[S]erver` and
`from[_]pretrained`. Their accepted input language is unchanged. No scan roots,
checks or exclusions changed. Scanner SHA-256:
`6254f70911146a344c22271bbc9d5c699950fd6eb5dddde95804a6b632acf249`.

The behavioral probe copies the scanner verbatim to a temporary script inside
its existing scan roots and invokes `scripts/verify-offline-test-surface`.
Before the correction, it exits **1**, identifying the copied pattern declaration
as forbidden input. The identical probe after correction exits **0**. The existing
scanner-filename exclusion already allowed the original clean repository; this
probe exposes the declaration's self-trigger without removing that exclusion.
Temporary probe files are removed in a finally block.

A separate probe writes each of 18 forbidden strings individually into a temporary
file in `test/` or `scripts/` and invokes the real scanner. Every case exits **1**
and identifies the exact fixture path and line. Inputs are text only; none is
executed. Cases cover TCP/TLS calls, both server names, model/tokenizer loading,
process/timer sleeps, timer/monotonic/system clocks, duration/elapsed thresholds,
`curl`, `wget`, dependency fetching and both Hex registry commands. The clean
repository then exits **0**. Complete captured probe output is archived with the
execution evidence. The behavioral proof JSON records actual rejecting/corrected
exit codes and existing logs; its shape and types are validated.

The existing interrupted-turn public-API assertions and all contract-selected
cases remain unchanged from the tested base revision.

## Final gates

All nine `.hone-gates.json` commands exited zero. Runtime: pinned Elixir 1.18.5 /
OTP 28.5.0.7, MIX_ENV=test, HEX_OFFLINE=1. Hashes identify complete stdout captures
archived with execution evidence, without depending on disposable checkout paths.

| Command | Exit | Stdout SHA-256 |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `3d76eae3fd136ef6ebf2edd6a93e3494c93c2018d67d2e198283fd771e43d2fe` |
| `scripts/recovery-mix credo --strict` | 0 | `7d9e4abe195a69b443ab4a07f8b541d533d8757d84768664e04473f087f9af61` |
| `scripts/recovery-mix test --cover` | 0 | `7534384089cc7939e69587a3e630afa89f79496c4356cb900c65de1f161b551c` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-first-token-contract` | 0 | `d03416517bd3fb1cd0a66de505e473a75ec382d70103aed702654833848f5017` |
| `scripts/verify-readiness-contract` | 0 | `175f5bf958c132bbd0990f48bacc27ff2cc373b1238a7c238c051b8b32f40b68` |
| `scripts/verify-packaged-first-token` | 0 | `dac5d0f51b6322586b34e4e50b9291768f2670d5448c6bb384bf3a8b57ac08bb` |

test:

```text
Finished in 198.6 seconds (119.0s async, 79.5s sync)
22 doctests, 6084 tests, 0 failures
    91.43% | Total
```

first-token-contract:

```text
Finished in 42.0 seconds (0.00s async, 42.0s sync)
864 tests, 0 failures
```

readiness-contract:

```text
Finished in 205.8 seconds (129.8s async, 75.9s sync)
5395 tests, 0 failures
```

packaged-first-token:

```text
Finished in 217.5 seconds (138.5s async, 78.9s sync)
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

Supplementary checks retained from the base revision (not rerun for this scanner-only correction):

| Command | Environment | Exit | Stdout SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix test test/mojentic/realtime/session_test.exs:427` | `test` | 0 | `a9fa2aaa731761947a8d0f9b2913042568b59147fbda2437a7d602bb33dc2d69` |
| `scripts/recovery-mix dialyzer` | `test` | 0 | `0118ef81e344612313be85b1f962049fe6b88c5f0fcfe92d32093d2773159126` |
| `scripts/recovery-mix hex.audit` | `test` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` |
| `scripts/recovery-mix hex.outdated --all` | `test` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` |
| `scripts/recovery-mix docs` | `dev` | 0 | `0583ac826ef2f3f6e0588417c85a8f43be2fa0eabad0d8b4c18586e78e476967` |

The base-revision checks reported zero Dialyzer errors, skips or unnecessary
skips and no retired or security-advisory packages from Hex audit. Hex outdated
exited 1 for available updates;
this is informational and no dependency is changed. The documentation build
succeeded with existing missing-link warnings for `LICENSE`,
`../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`. The current strict Credo and
compilation gates also pass, as recorded above.
