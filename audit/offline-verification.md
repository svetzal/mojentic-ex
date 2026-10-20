# Offline verification

## Tested revision and scope

This correction tests base commit
`ff478c46b6d4d2e16bd127fbf7e9c0161a72605e` plus the uncommitted changes in this
worktree. A read-only remote check confirmed that `main` still identifies that
commit. The complete preserved correction from
`43b959700536e5c36bb747e9c85beea5dc44e7e2` was reapplied: portable scanner and
regressions, Finch connection guard, deterministic date cases, shared harness
manifests and living conformance/audit evidence.

Stacey's October 19 decision authorizes the additional internal clock seam.
Public APIs, dependencies, runtime pins, versions and CI wiring are unchanged.
Foundry owns Git finalization; no commit, push, merge, rebase, release or ref
update is performed. Only this worktree is edited.

## Scanner and connection boundary

The scanner uses host `find` and `grep`, preserving path/line diagnostics,
filename exclusions, timing-assertion scope and scripts-only registry-command
scope. Grep errors fail closed. The scanner now also rejects direct UTC/calendar
reads. Its regression executes inert forbidden-operation fixtures, indented
commands, command-prefix acceptance, filenames containing spaces and a missing
grep check with a minimal PATH containing no ripgrep.

The preserved run's negative control showed that the old scanner exited zero
when `rg` was absent; the replacement rejects those same fixtures. The preserved
Finch guard negative control emitted one synthetic connection event without
opening a socket and correctly failed the suite.

ReqClient creates dedicated lazy Finch pool supervisors before dispatch. Pool
startup does not connect: the in-process `ScriptedTransport` Req adapter receives
prepared requests and delivers response messages without sockets. Pool endpoint
identifiers are synthetic. The shared test helper counts actual
`[:finch, :connect, :start]` events and fails if any connection was attempted;
source, complete-suite and fresh Hex consumers all retain this guard. Production
request preparation, dispatch, observation, cancellation and pool cleanup remain
in place.

## Simulated clocks and scheduling

`Mojentic.Clock` is an internal behaviour and application-configured boundary.
Its default implementation delegates to the original monotonic and UTC clocks
and sleeper. ReqClient's deadlines and remaining-time calculations use this seam.
The clock search also covered date fallback, broker and tool duration capture,
realtime duration capture, tracer timestamps, default recovery clocks and the existing stream clock.
Only the default clock implementation reads real time or sleeps directly.
Existing request-specific clock callbacks retain precedence.

The shared test helper installs a fixed clock at `2026-01-01T00:00:00Z`, with
monotonic milliseconds initially zero and a no-op sleeper. Serial tests install a
shared atomic counter for explicit advancement across callers and workers.
No test reads the system clock, sleeps or asserts measured elapsed time.

Named behavioral checks include:

- ReqClient: **absolute deadline expires after explicit clock advance for HTTP
  200/503**. After a body fragment, explicitly advance 1000ms, verify the clock
  boundary observed that value, and assert exact timeout events, retained failed
  response evidence, cleanup and one request. For HTTP 200, queue completion
  before the next read to prove simulated expiry wins without a transport wait.
- CurrentDatetime: **returns timestamp as unix epoch**, exact default/custom
  dates, weekday, month and year. The epoch test advances one second and asserts
  exact changed outputs. Its initial red run failed against the real-clock
  implementation, establishing that the fixed assertions detect the omission.
- DateResolver: **uses the injected current date when the reference date is
  absent or invalid**, then explicitly advances a day. Preserved explicit
  year-boundary and leap-day cases remain.
- TracerSystem: **records timestamps from the explicitly advanced clock** checks
  exact fractional Unix timestamps from a supervised tracer before and after
  a 1250ms advance. OS timestamp capture retains the original production clock.
- AsyncDispatcher: tests send `:process_events` directly after public dispatch,
  exercise queue draining with fixed time and no sleeping, and use worker
  monitors for controlled releases. **processes sequentially dispatched events
  in order** waits for each event before sending the next; worker scheduling is
  not an ordering assertion. Queue-empty checks follow public drain barriers.

## Shared executable contracts

Source public-API consumer/provider verification and a fresh extracted Hex
consumer/provider verification execute the same **ex-readiness-v1** file set.
Both verify the manifest; the fresh consumer additionally checks extracted
provider files and copied consumer inputs, compiles the package afresh and
verifies its loaded ReqClient path. The existing file set now also includes the
datetime, date-resolver, tracer and dispatcher tests; ReqClient's new clock cases already
belong to it. Both manifests identify the new internal clock and test clock.
Root contract text and binding 3.0.0 decisions are unchanged. No sibling
repository or running-service boundary changed.


| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `56ff70a4da7183b3a031fc923bec09973ad58b7b70a9b5f850417089e0c19676` |
| `test/contracts/readiness_v1.manifest.sha256` | `7cfad313c26222618e3a4c9c659992ec8be05c999fef0e0d928602fec9e568db` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `5e99b073daa017daf5020ffc2a64094a3ee6457e71f5531fe7c904f717549ef3` |

## Final local verification

All nine `.hone-gates.json` gates and the exact CI readiness step passed on Linux. Every final command ran with pinned Elixir **1.18.5** and OTP **28.5.0.7**, local Hex caches, and a PATH verified to contain no `rg`. The CI step used `MOJENTIC_MIX=mix scripts/verify-readiness-contract` with the pinned `mix` on PATH.

| Check | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `53c6c10fb05613575836a8688bce8ab92ee3238ee1cf5ae8daf82c120949c49f` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `e41e65dc8e30a42e13a8ecebd059629190fb2004bea47d271c94a657f73838f2` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `6436a76f6c9f215476e71c23607008bfa1b717cb8c20c2fb6b07f4625ac5e6ce` |
| `scripts/verify-first-token-contract` | 0 | `87880f35f2f6e431276d0b49d5e3e5ea5d46d761aa9db5c624e849a1c11c74c0` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `d808cbfc67c6699ab90eb6ca092ef3993339d24fcdee59cfc53725ed1c791284` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-packaged-first-token` | 0 | `18b588a1056630c6b0f9e643c8900288012ccd04878b992ab33a8ea784ba4787` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MOJENTIC_MIX=mix scripts/verify-readiness-contract` | 0 | `e30d48936779eea77765ab55d50823dfa0381a697de97b71a82458dcf4233b03` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.audit` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.outdated --all` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MIX_ENV=dev scripts/recovery-mix docs` | 0 | `60a11d865b9a8d02898f2f5328666b0f28b1cd6a911bffc8f845e128b1a9cfe5` | `12f66072abf2e3ab2e2875f9eda10da6690da37c1875e8cbc8afcf2fc0276f7f` |
| `scripts/recovery-mix dialyzer` | 0 | `e965b62aee848e89951f9b43818f096b24d6d59427d327e29d1a156c348e6a3a` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MIX_ENV=dev scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

| Suite | Result |
| --- | --- |
| test | 22 doctests, 6088 tests, 0 failures; zero Finch connection attempts |
| first-token-contract | 864 tests, 0 failures; zero Finch connection attempts |
| readiness-contract | 5489 tests, 0 failures; zero Finch connection attempts |
| packaged-first-token | 5489 tests, 0 failures; zero Finch connection attempts |
| ci-readiness | 5489 tests, 0 failures; zero Finch connection attempts |

Coverage: `91.39% | Total` (required threshold: 80%).

Local Hex payload: version **3.0.0**, SHA-256 `bfa6dd8671f125ec9329e0ab3ccabdaa2701d89db4da590cf200119347fac426`. The fresh consumer checked extracted provider inputs and copied contract inputs, compiled the provider from that payload and verified its loaded ReqClient path. No package was published.

Dialyzer passed with zero errors; strict Credo found no issues. Hex outdated is informational and exited 1 for available upgrades; dependencies and advisory suppressions are unchanged. Dependency audit reported no vulnerabilities using advisory commit `83be990cdd1105386d97f133b041215e97a58a61`; Hex audit reported no retired or security-advisory packages in the local registry. Documentation built with existing missing links to `LICENSE`, `../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`. Sobelow passed with its existing missing-router diagnostic for this non-Phoenix library and quoted-key parsing warnings from the unchanged lockfile. Initial compilation of unchanged third-party development dependencies also emitted their existing deprecation warnings; project warnings-as-errors compilation and strict Credo passed.

## Execution identity and finalization

Execution-tree SHA-256: `e8d63bac478740195fe52803209707552fd36595bb4b0ee0aa851a83dc545dd7`. This hashes sorted path/digest records under `lib/`, `test/`, `scripts/`, `.github/workflows/`, plus `mix.exs`, `mix.lock`, `.formatter.exs` and `.hone-gates.json`; living evidence prose is excluded.

Base commit `ff478c46b6d4d2e16bd127fbf7e9c0161a72605e` plus this execution identity identifies both provider and consumer verification. All changes remain uncommitted for Foundry. GitHub Actions was not monitored; these are local verification results.
