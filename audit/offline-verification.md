# Offline verification

## Tested revision and reconciliation

Both source and fresh local-Hex consumers test base revision
`3dd2aa35b740a815ba5e8e09556957cdbd430add` plus the uncommitted scanner
correction, executable regression and readiness gate wiring identified below.
The preserved migration and retry-cancellation correction are retained. Trunk release commit `38875faede2679690483d7b8ec2f70fdeefafaaa` is
already an ancestor: `mix.exs` version 3.0.0 and CHANGELOG match trunk exactly.
No merge or ref changes were needed. Production `lib` tree
`b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`, dependencies, runtime pins,
public APIs and the 80% coverage floor are unchanged. Git finalization belongs
to Foundry; all correction changes remain uncommitted.

The tested source execution tree SHA-256 is `cf46d75cbc60253eb2b7ddf1f98c59d4b7cd04a8ba64b3eb7bbfc44d4831aaf8`.
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
Mojentic. HEX_OFFLINE=1 prevents registry access; neither contract verifier
publishes or runs deps.get.

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `80141cf30a543b798d5818c29c1e8af9bd4d027345fbe312f064f23a8a5b8faf` |
| `test/contracts/readiness_v1.manifest.sha256` | `8943fc5e40b09ecdb8df34d433b6fbb0c5e309ded17c15b44cdc92bfd123a6ca` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `88962afa7cb210f63448c3ebb672ae677ab1152c1e7969a11153d6478aed585a` |

Tested Hex artifact: local `mojentic.tar`, package version **3.0.0**, SHA-256
`40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`. The payload is built locally and never published.

## Scanner declaration proof

The surviving literal socket-module token in the detector declaration is now
spelled `:gen[_]tcp`. This preserves the regex's accepted operation language.
All scan roots, checks and exclusions are unchanged. Scanner SHA-256:
`8f3c89c2da2552a737e790ee7778fcbf32b828ab93114c043759c1aaefe19a86`.

`scripts/verify-offline-test-surface-regression` is executable regression evidence,
identified by readiness-v1 and run by source readiness verification. It copies
the actual scanner to an isolated temporary root and invokes its command API.
Fixtures are inert text and are never executed. The scanner accepts a verbatim
copy of its corrected declaration, while a separate literal-token assertion
ensures the declaration also passes literal socket-token audits.

The initial probe rejected a socket operation and accepted the copied declaration,
but exited **1** because the original declaration retained the literal token.
After the source correction, the identical probe exited **0**. The corrected
regression now checks 44 fixture cases: 35 prohibited inputs must exit **1** and
identify the fixture path and line, and nine allowed inputs must exit **0**.
It exercises TCP connect/listen, TLS, both server names, both scan roots,
process/timer sleeps, timer/monotonic/system clocks, tokenizer/model loading,
duration/elapsed thresholds, download commands and dependency/Hex registry
commands. It also verifies outside-root, filename and extension exclusions,
and the registry check's scripts-only scope. Temporary roots are cleaned up.

The regression builds prohibited strings from fragments so its own inert fixture
declarations do not trigger the production scanner. The actual repository scan
and regression both pass. Rejecting/corrected proof records, complete captures
and validation are archived as execution evidence.

The existing interrupted-turn public-API assertions and all contract-selected
cases remain unchanged from the tested base revision.

## Final gates

All nine `.hone-gates.json` commands exited zero. Runtime: pinned Elixir 1.18.5 /
OTP 28.5.0.7, MIX_ENV=test, HEX_OFFLINE=1. Hashes identify complete stdout captures
archived with execution evidence, without depending on disposable checkout paths.

| Command | Exit | Stdout SHA-256 |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `20fb5a055b481af6b570ce833d18209f81f39de0eb80f0a71c74634f1d087392` |
| `scripts/recovery-mix test --cover` | 0 | `4d009b10b2d82c5075502b3bc4189e3a756942c7d1cc6e6a8f15a9e5ca071a82` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-first-token-contract` | 0 | `3d83939e2f14f46fa124dae6341d40844a245eb61a63074ce68c4c7159679d6e` |
| `scripts/verify-readiness-contract` | 0 | `4869742bf0a982b67172f646fcedd49add998059ba713378d0028811eccab0f8` |
| `scripts/verify-packaged-first-token` | 0 | `39fcd8e473ad4cdb76ecaea23197bdd2dc35c6df3d979b45cf14fc0ace30a73b` |

test:

```text
Finished in 185.9 seconds (109.0s async, 76.8s sync)
22 doctests, 6084 tests, 0 failures
    91.43% | Total
```

first-token-contract:

```text
Finished in 41.4 seconds (0.00s async, 41.4s sync)
864 tests, 0 failures
```

readiness-contract:

```text
Finished in 178.8 seconds (104.7s async, 74.1s sync)
5395 tests, 0 failures
```

packaged-first-token:

```text
Finished in 167.5 seconds (94.2s async, 73.2s sync)
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

Supplementary checks rerun for this correction:

| Command | Environment | Exit | Stdout SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix dialyzer` | `test` | 0 | `7266721b6e2ee423c47300727d9baa320f9fe88cc11d8b32e624d79e7db1ca26` |
| `scripts/recovery-mix hex.audit` | `test` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` |
| `scripts/recovery-mix hex.outdated --all` | `test` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` |
| `scripts/recovery-mix docs` | `dev` | 0 | `a2d5b3c1f9bcaa4e317a6050a34a864a5f57a1b844f887c5f01a4d6d1aca71a3` |

Dialyzer reported zero errors, skips or unnecessary skips. Offline Hex audit
reported no retired or security-advisory packages. Hex outdated exited 1 for
available updates from the local registry snapshot; this is informational and
no dependency is changed. The documentation build succeeded with the existing
missing-link warnings for `LICENSE`, `../RELEASE-3.0.0.md` and
`deps/igniter/usage-rules.md`.

The initially empty worktree dependency directory was restored with
`HEX_OFFLINE=1` from the existing local Hex cache, without changing `mix.lock`.
All gates then ran against the pinned runtime and local dependency/NIF caches.
