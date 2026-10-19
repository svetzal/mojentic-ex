# Offline verification

## Tested revision and reconciliation

The final consumers test base revision
`085a360cedd3a77055352ea97c42bb42806a8903` plus the uncommitted shutdown evidence correction in
worktree `mojentic-ex-no-network-tests-c10-336be6`. Git finalization belongs to Foundry.
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
in the correction plan. The prior audit also records an unchanged baseline packaged rerun with seed 0
passing (5395 tests). Together with the reported failure, this is consistent
with intermittency; it does not establish the failure cause or the adequacy of
the default 100 ms receive bound. This run does not independently reproduce
that historical failure. The final results below supersede the old
execution claims. Git retains the earlier evidence.

## Shutdown acceptance probe

Public `Session.subscribe/1` and the existing in-process FakeTransport exercise
server-close delivery, session termination and synchronous transport cleanup.
The opt-in transport hold preserves the ordinary close behavior for every other
session test. It accepts the original session's GenServer close request without
replying, sends a cleanup-entry observation identifying that session and itself,
and remains responsive to an explicit release request. No process suspension,
sleep or timeout is used to manufacture rejection.

Both original PIDs are monitored before server-close is pushed. The subscriber
receives the server-close event, and the transport reports cleanup entry for
those same PIDs. The probe rejects this observed incomplete state immediately
with `{:error, observations}`: delivery is `:server_close`, cleanup and both
exits are pending. Release replies to the saved original close request and
reports cleanup completion. Exact monitor DOWN messages must then identify the
original session and transport with reason `:normal` before the same probe can
accept. Completion notifications alone, counts, replacement PIDs and `:noproc`
are insufficient. The 2000 ms receive bounds only cap failure latency.

The rejecting run temporarily required `:ok` from the pending-cleanup result.
It exited **2** on `assert :ok = rejected`, reporting the actual error map,
not a receive timeout. Its original session was `#PID<0.242.0>` and transport
`#PID<0.241.0>`. Before that intentional assertion failure, cleanup was released
and both original PIDs were observed exiting with exactly `:normal`; the completed
state was accepted by the same probe. The corrected run asserts rejection of
the pending state and acceptance of the completed state; it exited **0** (one
selected test, 20 excluded). Its diagnostics likewise record the original
session `#PID<0.242.0>` and transport `#PID<0.241.0>`, first pending and then
completed with exact `:normal` exits. PID values are local to each separate VM.
The retained test performs this controlled comparison on every source and
packaged readiness run. Behavioral proof JSON and both complete logs are archived
by Foundry; actual exit codes, JSON types and log existence were checked.

| Focused probe | Exit | Diagnostic log SHA-256 |
| --- | --- | --- |
| rejecting | 2 | `0bb270a9c65d0688115382c64625e930779926beaaca77b164c5848ac223ee43` |
| corrected | 0 | `60e50d7eb79b31e54f4b2186e7fddae3d587331e6509e9882d69c92a9d438827` |

This demonstrates the event-before-cleanup mechanism and that the acceptance
probe distinguishes incomplete cleanup from completed shutdown. The earlier
control merely forced a DOWN timeout while transport cleanup was suspended;
that could not distinguish a broken harness from correct waiting. Neither
control reproduces the scheduling conditions of the historical intermittent
packaged failure. Its precise cause, including whether the old 100 ms receive
bound was responsible, remains uncertain. No production defect is established.

## Reproducible execution identity

Execution-tree SHA-256: `869cffeda35be810c84a0a1a09d0dbe5a816eb09d6f9f98bcfd76d93b3ce519d`.
This execution identity covers final execution files, including the regenerated readiness
manifest. Living evidence prose is excluded to avoid a self-referential digest.
Shutdown test SHA-256:
`f5c0b4970e4b4f12d9f7d462890a4110bb85513784d1da2f98ea960322b83da0`.
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
| `test/contracts/readiness_v1.manifest.sha256` | `08b4b87f38072b54b486539edb155636e94d0dc880034bb40208d4b6f1968b28` |
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
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `0daca94002829a17a11b6a579fb074d628eb0913000f6c62fde8f1b575bf4f0e` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `bb17942f5e4fac6cf7195398e9dab59711f8691d534493578af7edbbcd120375` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `f94b4dc19e44a739abacacbc13da38a1fd9f0a99001a5ebdc4c4759a9401d4d8` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `6436a76f6c9f215476e71c23607008bfa1b717cb8c20c2fb6b07f4625ac5e6ce` |
| `scripts/verify-first-token-contract` | 0 | `2c95736f1996e2e03237a0b457ca1d6f6a11deab67fc81d0e5a376e929d3e8a2` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `4c9111d5b0b69ba5415fe53021fc62e8e01bae1f995329e1559f847b49552bf2` | `ea16932fd9402c356d4f80adff0148745fe532b864a5b0097a7737c83451020c` |
| `scripts/verify-packaged-first-token` | 0 | `0e15515c2de5990940c7ce7892cdba3a6a5f65df303365afb8db9514290bd12b` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

| Verification | Final result |
| --- | --- |
| Complete suite with coverage | 22 doctests, 6084 tests, 0 failures; 91.45% total (80% threshold) |
| First-token contract | 864 tests, 0 failures |
| ex-readiness-v1 source public consumers/provider | 5395 tests, 0 failures |
| ex-readiness-v1 fresh local-Hex consumers/provider | 5395 tests, 0 failures; packaged provider build path verified |

| Consumer shutdown observations | Original session | Original transport | Exact exits after cleanup |
| --- | --- | --- | --- |
| `readiness-contract` | `#PID<0.533.0>` | `#PID<0.532.0>` | `:normal` / `:normal` |
| `packaged-first-token` | `#PID<0.1211.0>` | `#PID<0.1210.0>` | `:normal` / `:normal` |

Both readiness runs verify manifest SHA-256
`08b4b87f38072b54b486539edb155636e94d0dc880034bb40208d4b6f1968b28`
at base `085a360cedd3a77055352ea97c42bb42806a8903` plus the final uncommitted
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
| `scripts/recovery-mix dialyzer` | 0 | `91159ed93d5582a84c7a3472f354f99e070f97db852e3bbb38a3b3c2dddaca2f` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.audit` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.outdated --all` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix docs` | 0 | `0583ac826ef2f3f6e0588417c85a8f43be2fa0eabad0d8b4c18586e78e476967` | `a841706a35682fc906b07805e8bae0a31a21ff321cb23fc1dcaade970ecb21ca` |

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
