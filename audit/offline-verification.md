# Offline verification

## Tested revision and reconciliation

Both source and fresh local-Hex consumers test base revision
`81a6c64a9c3c4749d2182a980f49456b1ef243f7` plus the uncommitted regression
correction and readiness manifest identified below. Scanner implementation and
readiness gate wiring are unchanged.
The preserved migration and retry-cancellation correction are retained. Trunk release commit `38875faede2679690483d7b8ec2f70fdeefafaaa` is
already an ancestor: `mix.exs` version 3.0.0 and CHANGELOG match trunk exactly.
No merge or ref changes were needed. Production `lib` tree
`b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`, dependencies, runtime pins,
public APIs and the 80% coverage floor are unchanged. Git finalization belongs
to Foundry; all correction changes remain uncommitted.

The tested source execution tree SHA-256 is
`bd0144602e885ded406711a37b93171cb93b0011d65572c05ff305495ffaa580`.
Reproduce it from the repository root with Python 3:

```python
import hashlib
from pathlib import Path

roots = ("lib", "test", "scripts", ".github/workflows")
paths = {p for root in roots for p in Path(root).rglob("*") if p.is_file()}
paths.update(map(Path, ("mix.exs", "mix.lock", ".formatter.exs", ".hone-gates.json")))
records = b"".join(
    hashlib.sha256(p.read_bytes()).hexdigest().encode("ascii")
    + b"  " + p.as_posix().encode("utf-8") + b"\n"
    for p in sorted(paths, key=lambda p: p.as_posix().encode("utf-8"))
)
print(hashlib.sha256(records).hexdigest())
```

Selection includes every file (including hidden files) recursively beneath those
four roots for which `Path.is_file()` is true, following file symlinks, plus the
four explicit root files. There are no extension or ignore-file exclusions.
Paths are relative POSIX paths without a leading `./`, sorted by their UTF-8
bytes, independently of locale. Each record encodes the lowercase ASCII SHA-256
of the file's exact bytes, two ASCII spaces, the UTF-8 path and one LF byte.
The final digest hashes the concatenated records, including the last LF.
Audit and conformance prose, build outputs and execution scratch are outside
this selection, so updating this evidence does not change the execution identity.

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
| `test/contracts/readiness_v1.manifest.sha256` | `80bb7924330bca1d91038d1faa6ce3e18171eb81089a17a329d2232613e063c7` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `88962afa7cb210f63448c3ebb672ae677ab1152c1e7969a11153d6478aed585a` |

Tested Hex artifact: local `mojentic.tar`, package version **3.0.0**, SHA-256
`40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`. The payload is built locally and never published.

## Scanner declaration proof

The scanner remains byte-for-byte unchanged, SHA-256
`8f3c89c2da2552a737e790ee7778fcbf32b828ab93114c043759c1aaefe19a86`.
Its `:gen[_]tcp` declaration preserves detection strength; all scan roots,
checks and exclusions remain unchanged.

`scripts/verify-offline-test-surface-regression` is executable regression evidence,
identified by readiness-v1 and still run by source readiness verification. It
copies the actual scanner to an isolated temporary root and invokes its command
API. Fixtures are inert text and are never executed. The surviving literal
`.listen(` in the regression's fixture declaration is now assembled from separate
fragments. A literal-token assertion prevents its reintroduction.

Before expanding the regression or running quality gates, the same acceptance
probe ran against the original and corrected regression. In both runs, the
scanner rejected assembled TCP connect/listen fixtures in both `test/` and
`scripts/` with exit **1**, asserting the complete exact `path:2:operation`
output line, and accepted a verbatim copy of the inert regression declarations
with exit **0**. The initial probe then failed (exit **1**) on the surviving
literal socket-operation token. After splitting that token, the identical probe
passed (exit **0**). Rejecting/corrected logs and validated behavioral proof
are archived as execution evidence.

All 44 existing regression cases remain. Four additional socket fixtures put
connect/listen operations on line 2 in both roots; another case accepts the
verbatim inert regression itself. The resulting 49 cases comprise 39 rejected
and ten accepted fixtures. Every rejection asserts the complete diagnostic line
(path, line number and source text), rather than merely counting matches.
The scanner's own copied declaration remains accepted, and the existing
literal socket-module assertion is retained.

Coverage remains TCP connect/listen, TLS, both server names, both scan roots,
process/timer sleeps, timer/monotonic/system clocks, tokenizer/model loading,
duration/elapsed thresholds, download commands and dependency/Hex registry
commands. Outside-root, filename and extension exclusions and scripts-only
registry checks are preserved. The actual repository scan and regression pass;
temporary fixture roots are cleaned up.

The existing interrupted-turn public-API assertions and all contract-selected
behavioral cases remain unchanged from the tested base revision.

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
