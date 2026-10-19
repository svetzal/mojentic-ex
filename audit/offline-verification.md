# Offline verification

## Tested revision and reconciliation

Source and fresh local-Hex verification tested base revision `1b12afcb9d16c9800d7c6b29e339067d858aa242`
plus the uncommitted reconciliation of preserved correction
`01f2f1c4f936ece8f080e6da3a63733285cec301`. The preserved regression is restored
verbatim. Trunk’s realtime task receive bounds and corresponding readiness entry
are retained: `test/mojentic/realtime/session_test.exs` SHA-256
`07599e2c50abc9a3c702e1aa2cd6d896fa00e7a2e7eb22b977e2c51723be7bcf`.
The combined readiness manifest was regenerated from the reconciled files,
retaining every path and contract mapping.

Only the regression, readiness manifest and these living evidence documents
change. Production `lib` tree `b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`,
public APIs, all public-API assertions, dependencies, runtime pins, versions,
scanner detection, scan roots, exclusions and gate wiring are unchanged.
No refs were changed; Git finalization belongs to Foundry.
This record supersedes previous gate captures, artifact claims and execution
identities in this document; Git retains their history.

## Reproducible execution identity

Execution-tree SHA-256: `511be2e5c25ac521bac8a8609fd13cf372e9385e5ef3b888658eb658a913185a`.
This hashes the final reconciled execution files, including the combined manifest.
Living audit prose is excluded to avoid a self-referential digest. Reproduce from
the repository root:

```python
from pathlib import Path
import hashlib

roots = ("lib", "test", "scripts", ".github/workflows")
paths = sorted({p.as_posix() for root in roots
                for p in Path(root).rglob("*") if p.is_file()} |
               {"mix.exs", "mix.lock", ".formatter.exs", ".hone-gates.json"})
records = "".join(hashlib.sha256(Path(p).read_bytes()).hexdigest()
                  + "  " + p + "\n" for p in paths)
print(hashlib.sha256(records.encode()).hexdigest())
```

## Shared executable contracts

The shared set is **ex-readiness-v1**. Source public-API consumers/provider
verification and a fresh extracted Hex-payload consumer/provider verification
both execute `test/contracts/readiness_v1.files` at the tested revision above,
including realtime interruption. Both verify the combined manifest before
execution. The fresh consumer also checks extracted provider files and copied
consumer files against that same manifest, compiles the payload in its own build
and verifies that ReqClient loads from that build. The tests use the established
in-process Req adapters, gateway doubles and injected clocks; they require no
services, sockets, real sleeps or wall-clock assertions.

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `80141cf30a543b798d5818c29c1e8af9bd4d027345fbe312f064f23a8a5b8faf` |
| `test/contracts/readiness_v1.manifest.sha256` | `9f54664e5c3d933c89436f0550f554995af6a2faaa7af1c2a033ab3f089b3048` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `88962afa7cb210f63448c3ebb672ae677ab1152c1e7969a11153d6478aed585a` |

Fresh local Hex artifact: `mojentic.tar`, version **3.0.0**, SHA-256
`40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`. It was built, extracted and tested locally, never published.
Existing dependency sources/builds and Hex/NIF caches were copied into this
worktree from local caches; the packaged consumer reused dependencies only,
excluding Mojentic. `HEX_OFFLINE=1` prevented Hex registry requests; neither
contract verifier runs dependency downloads.

## Scanner command regression

Scanner SHA-256: `8f3c89c2da2552a737e790ee7778fcbf32b828ab93114c043759c1aaefe19a86`.
Regression SHA-256: `399f1e707dc5f9ac5cb337c776f6436f1e2e18b51046be3327c269679edd4c87`.
The detector remains byte-for-byte identical to trunk. Its character-class
socket declaration preserves detection strength. The regression assembles its
inert listen fixture from fragments and guards against a surviving literal
socket operation.

Before expanding fixtures or running full gates, the acceptance probe invoked
the scanner regression through its command interface. The original regression
exercised 44 fixtures, then the probe failed (exit **1**) on the inert fixture’s
literal socket operation. With the preserved correction restored, the identical
probe passed (exit **0**). Complete rejecting/corrected logs and the validated
behavioral proof are archived with execution evidence.

The restored regression retains all existing cases and adds four TCP
connect/listen fixtures on line two in both `test/` and `scripts/`, plus acceptance
of a verbatim copy of the inert regression. Its **49 cases** comprise **39
rejected** and **10 accepted** fixtures. Each rejected case asserts a complete
exact diagnostic line containing path, line number and source text. Fixtures are
inert text, never executed. The real repository scanner also passed.

Coverage includes both roots, TCP connect/listen, TLS, server names,
process/timer sleeps, timer/monotonic/system clocks, tokenizer/model loading,
duration/elapsed comparisons, download and dependency/registry commands.
Outside-root, filename and extension exclusions and scripts-only registry scope
are retained. The copied detector declaration and regression are accepted;
literal-token safeguards also pass.

## Final gates

All nine `.hone-gates.json` commands exited **0** against the execution tree
above. Runtime: pinned Elixir **1.18.5**, OTP **28.5.0.7**; `MIX_ENV=test`,
`HEX_OFFLINE=1`. Capture hashes identify complete archived stdout/stderr without
making this document depend on disposable execution paths.

| Command | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `3d76eae3fd136ef6ebf2edd6a93e3494c93c2018d67d2e198283fd771e43d2fe` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `35225995761ac1778044de016c431ce502c543ef9d71d381e18d9381e74875fe` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `87294b1c8c962ac14fee21fc8da574957a201e89a6b7a50e0b065ebecb349055` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `f94b4dc19e44a739abacacbc13da38a1fd9f0a99001a5ebdc4c4759a9401d4d8` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `6436a76f6c9f215476e71c23607008bfa1b717cb8c20c2fb6b07f4625ac5e6ce` |
| `scripts/verify-first-token-contract` | 0 | `3b6d096fc9bfc63e419acdd0298254aeff295d8516bdb8a9246d707a506033dc` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `48778e2bc6b6afe928cea66bb048372ec33eb118f0e6ef44681441a39df0e843` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-packaged-first-token` | 0 | `1a85518a6d9678b920875b967eecfde4004df8d97da6fe76dffa7cebcd65cf75` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Dependency audit used local advisory snapshot
`83be990cdd1105386d97f133b041215e97a58a61`. The refresh failed before fetching
with `cannot open '.git/FETCH_HEAD': Read-only file system`; the audit then
reported no vulnerabilities from that existing snapshot. This is offline
snapshot evidence, not a claim of refreshed advisories.

test:

```text
22 doctests, 6084 tests, 0 failures
    91.43% | Total
```

first-token-contract:

```text
864 tests, 0 failures
```

readiness-contract:

```text
5395 tests, 0 failures
```

packaged-first-token:

```text
5395 tests, 0 failures
```

## Additional quality checks

| Command | MIX_ENV | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- | --- |
| `scripts/recovery-mix dialyzer` | `test` | 0 | `8be1a3f24055c58200cc0849b17d61a35e1c0add7520918993e0c6a40b1bc61a` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.audit` | `test` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.outdated --all` | `test` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix docs` | `dev` | 0 | `0583ac826ef2f3f6e0588417c85a8f43be2fa0eabad0d8b4c18586e78e476967` | `a841706a35682fc906b07805e8bae0a31a21ff321cb23fc1dcaade970ecb21ca` |

All checks used the pinned runtime and `HEX_OFFLINE=1`.

Dialyzer result:

```text
done in 0m43.8s
done in 0m53.22s
done in 3m32.21s
Total errors: 0, Skipped: 0, Unnecessary Skips: 0
done in 0m10.03s
done (passed successfully)
```

Hex audit result from the local registry snapshot:

```text
No retired or security advisory packages found
```

Hex outdated used the local registry snapshot; available updates are informational.
No dependency or advisory suppression changed.

The documentation build completed with existing missing-link warnings for
`LICENSE`, `../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`.
Sobelow completed with its non-Phoenix router warning and warnings about quoted
keys while parsing the unchanged lockfile. These are retained in the captures;
strict Credo and warnings-as-errors compilation passed.
