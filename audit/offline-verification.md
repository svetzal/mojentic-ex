# Offline verification

## Tested revision and reconciliation

The final consumers test base revision
`31a35f68de33ba198f2a82b9d4354146b717b0cd`, also the preserved branch
`foundry-task/mojentic-ex-mojentic-ex-no-network-tests-c8-a5f6e4`, plus the
uncommitted shutdown harness correction in worktree
`mojentic-ex-no-network-tests-c9-c7bd4a`. Git finalization belongs to Foundry.
The earlier scanner correction remains verbatim: exact path/line/source
rejections, scanner strength, roots, exclusions and all binding contract mappings
are unchanged. Realtime interruption synchronization and task receive bounds
are retained. Only the realtime test/double, its readiness manifest entry and
living conformance/audit evidence change. Production `lib` tree remains
`b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`; public APIs, dependencies, runtime,
versions and release state are unchanged.

The previous record claimed passing source and packaged captures on base
`1b12afcb9d16c9800d7c6b29e339067d858aa242` plus preserved scanner correction
`01f2f1c4f936ece8f080e6da3a63733285cec301`. Those captures do not invalidate
the later packaged-consumer `realtime_close stops the session` failure reported
in the correction plan. An unchanged baseline packaged rerun with seed 0 also
passed (5395 tests); that establishes intermittency, not proof that the default
100 ms receive bound is sufficient. The final results below supersede the old
execution claims. Git retains the earlier evidence.

## Shutdown acceptance probe

Public `Session.subscribe/1` and the existing in-process FakeTransport exercise
server-close delivery, session termination and synchronous transport cleanup.
Session emits the server-close event before its termination callback finishes
closing the transport; that event alone cannot establish process termination.
Both exact PIDs are monitored before delivery. The test queues delivery while
the session is suspended, suspends the transport, then resumes the session.
FakeTransport closes through its ordinary GenServer request handler, allowing
that cleanup boundary to be held with a process barrier. A system stop would
bypass a suspended GenServer's ordinary mailbox and cannot establish this hold.
After server-close receipt, the test rejects an already queued session DOWN,
releases transport cleanup in `after`, then requires exact session and transport
DOWN messages with `:normal`. No `:noproc`, replacement PID, event-only success,
real sleep or elapsed-time assertion substitutes for those exits. The explicit
2000 ms receive bounds only cap failure latency.

The rejecting control placed the old default-bound exact-session DOWN assertion
before releasing held cleanup. It failed with exit **2**, reporting no matching
message after 100 ms. Correcting that ordering passed with exit **0**; the
formatted final test was rerun and passed (one selected test, 20 excluded).
The behavioral proof records actual exit codes and full rejecting/corrected
logs in Foundry's archived execution evidence; its JSON shape, types and log
existence were validated. This controlled reproduction proves the premature
assertion and the corrected shutdown behavior. It does not independently
reproduce the scheduling conditions of the reported intermittent failure or
claim a production defect. No production change was needed.

## Reproducible execution identity

Execution-tree SHA-256: `a4dd07d2d533d8ef010490c2353fbe9f92a1531861ea2a246a89c8fb8a0bc783`.
This execution identity covers final execution files, including the regenerated readiness
manifest. Living evidence prose is excluded to avoid a self-referential digest.
Shutdown test SHA-256:
`b97578268030e7397b8eb9ae5ee71088976a57386cea00c13b834298d14633f1`.
Reproduce the execution-tree digest from the repository root:

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
including realtime interruption and exact-session shutdown. Both verify the
combined manifest before execution. The fresh consumer also checks extracted provider files and copied
consumer files against that same manifest, compiles the payload in its own build
and verifies that ReqClient loads from that build. The tests use the established
in-process Req adapters, gateway doubles and injected clocks; they require no
services, sockets, real sleeps or wall-clock assertions.

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `80141cf30a543b798d5818c29c1e8af9bd4d027345fbe312f064f23a8a5b8faf` |
| `test/contracts/readiness_v1.manifest.sha256` | `46fff6e33a8a4e6fc623ece97df6296535684b2c42bf9ba34fd5a2801da65c5d` |
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

The preserved scanner correction originally rejected the inert fixture's literal
socket operation; fragment assembly corrected that fixture. In this run the
unchanged command regression passed all 49 cases (exit **0**), including the
exact diagnostic checks. The source readiness gate also runs the repository
scanner and this same regression.

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

All nine `.hone-gates.json` commands exited **0** against the final execution
tree above. Runtime: pinned Elixir **1.18.5**, OTP **28.5.0.7**;
`MIX_ENV=test`, `HEX_OFFLINE=1`. Hashes identify complete archived stdout/stderr
without depending on disposable execution paths.

| Command | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `932fc1049eb492b084d0741e96c457dfafba097e5db592d2799199594663d47d` |
| `scripts/recovery-mix credo --strict` | 0 | `13dd5fe13890f0c566bcc118759c36fbc85b5efec98b601a4556971604f30aec` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `a49312fd4aa4051332fd96dc4cc15322b5cb2c2fd03986bd86f03b91c21cb068` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `f94b4dc19e44a739abacacbc13da38a1fd9f0a99001a5ebdc4c4759a9401d4d8` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `21cb799fb7d41faf903e8df55c9e8298b07e3999fe29e8d596b2eb0d700e4a6e` |
| `scripts/verify-first-token-contract` | 0 | `9dc1ba321e8f356efc7b43aafded19653c3f5d8053f64763cc4ee295a795ba5f` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `959007562900a1f21cb3278327b86de455b050e9a06eaad81eaee16277ff3697` | `94c7653fbe05579f2e93c25b6e01e22c65fa437983d28f12698728ed5aa0aac2` |
| `scripts/verify-packaged-first-token` | 0 | `28acc69e71a75a397899265af6f014a4a3ab810679b9e43e4e6f4d0e8f1702ef` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

| Verification | Final result |
| --- | --- |
| Complete suite with coverage | 22 doctests, 6084 tests, 0 failures; 91.43% total (80% threshold) |
| First-token contract | 864 tests, 0 failures |
| ex-readiness-v1 source public consumers/provider | 5395 tests, 0 failures |
| ex-readiness-v1 fresh local-Hex consumers/provider | 5395 tests, 0 failures; packaged provider build path verified |

Both readiness runs verify manifest SHA-256
`46fff6e33a8a4e6fc623ece97df6296535684b2c42bf9ba34fd5a2801da65c5d`
at base `31a35f68de33ba198f2a82b9d4354146b717b0cd` plus the final uncommitted
execution-tree identity above. The package artifact retains the same hash as
the earlier payload because production package inputs did not change; its
consumer test harness is now identified by the updated shared manifest.

Dependency audit used local advisory snapshot
`83be990cdd1105386d97f133b041215e97a58a61`. Refresh failed before fetching
with `cannot open '.git/FETCH_HEAD': Read-only file system`; the audit reported
no vulnerabilities from that existing snapshot. This is offline snapshot
evidence, not a claim of refreshed advisories.

## Additional quality checks

All checks used the pinned runtime and `HEX_OFFLINE=1`; docs used `MIX_ENV=dev`,
the other Mix checks used `MIX_ENV=test`.

| Command | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix dialyzer` | 0 | `af04b61ba4533305aaf61cbda98634ce8411628d42b4a54ccd6c60eba4ab108f` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.audit` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.outdated --all` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix docs` | 0 | `0583ac826ef2f3f6e0588417c85a8f43be2fa0eabad0d8b4c18586e78e476967` | `a841706a35682fc906b07805e8bae0a31a21ff321cb23fc1dcaade970ecb21ca` |
| `scripts/verify-offline-test-surface-regression` | 0 | `0f3e8d331a8819cd12ccf5ff1f0e48b736e156bbaf49bec9baf0d30d884795c4` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

Dialyzer completed with zero errors, skipped checks or unnecessary skips.
Strict Credo found no issues. Hex audit found no retired or security advisory
packages in the local registry snapshot. Hex outdated exited 1 to report
available upgrades; it is informational, and no dependency or advisory
suppression changed.

Documentation built with existing missing-link warnings for `LICENSE`,
`../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`. Sobelow completed with
its non-Phoenix router warning and quoted-key warnings while parsing the
unchanged lockfile. These remain in the captures; warnings-as-errors
compilation and strict Credo passed.
