# Offline verification

## Tested revision and scope

This correction tests base commit
`169b741f93616d095352c429c3f57ab151deeba5` plus the uncommitted changes in this
worktree. A read-only `git ls-remote origin refs/heads/main` check confirmed that
remote `main`, local `main` and this worktree identify that commit; no ref update
was needed. The remaining native-tool timeout trigger from that commit is
replaced with explicit timeout delivery through an internal scheduling seam.

Stacey's October 19 decision authorizes this internal injection.
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

The suite-wide timeout audit covered `Task.async_stream`, `Task.yield`,
`Task.await`/`await_many`, receive-after clauses, `Process.send_after` and numeric
timeout options, including negative receive assertions. NativeResponseTest's
5ms runner timeout and two 200ms silence windows in SimpleRecursiveAgentTest
were the remaining elapsed-time triggers. All three are now deterministic.
Other task and receive bounds wait for explicitly released work and cap failure
latency; they do not trigger expected outcomes. ReqClient deadline tests advance the injected clock;
its zero-time receive probes consume queued evidence or expire immediately.
Dispatcher and aggregator zero-time probes hold work pending or leave required
events absent. No other real-delay test trigger was found.

`Mojentic.TaskStream` is the internal scheduling behaviour, configured like the
clock seam. Production delegates directly to `Task.async_stream/3`, preserving
all concurrency, ordering, timeout and kill options. The serial native response
test installs a Mox double only at this scheduling boundary and restores its
configuration on exit. Its lazy stream invokes the real tool on a supervised
worker, identifies the worker from its start message, monitors it, explicitly
kills it, requires its actual `:killed` DOWN reason, then delivers the timeout
result. No timer is armed. The public runner must preserve `timed-id`/`wait`,
return `{:task_exit, :timeout}`, and emit exactly one matching completion callback.
Other runner tests continue to exercise the default production scheduler.

The recursive emitter's **unsubscribes from events** and **supports different
event types** checks use supervised emitters. Before emission, they trace actual
callback spawning and exits; a GenServer barrier establishes emission handling,
then `trace_delivered` establishes complete spawn observations. They require
all observed callback workers to exit `:normal` before checking mailbox absence.
This also catches an unwanted callback that has been spawned but not yet run.
A temporary negative control dispatched each event to every subscriber; the
second check failed specifically on the unexpected `{:goal_achieved}` message.
The production change was restored before final gates. The corrected emitter
file passed all 22 tests. No production emitter change remains.

## Shared executable contracts

Source public-API consumer/provider verification and a fresh extracted Hex
consumer/provider verification execute the same **ex-readiness-v1** file set.
Both verify the manifest; the fresh consumer additionally checks extracted
provider files and copied consumer inputs, compiles the package afresh and
verifies its loaded ReqClient path. The file set now includes
`native_response_test.exs` and `simple_recursive_agent_test.exs`, so all three
deterministic cases run on both sides. Updated manifests identify the scheduler seam, runner and shared
test helper where selected; existing clock cases remain in place.
Root contract text and binding 3.0.0 decisions are unchanged. No sibling
repository or running-service boundary changed.


| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `c803c59e808bd28d365ac24b62fe3b32c43b94637255ade8f27187f6f484a8fa` |
| `test/contracts/readiness_v1.manifest.sha256` | `cb7d11ed019ff4918c7c76e3a16d345914cbeae1eaee5d1cfeb988c336bb5502` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `ea8fa8a4fc37427e9b5f1306447c3788d40a032fb997eb59fd4d9460726dd220` |

## Final local verification

All nine `.hone-gates.json` gates and the exact CI readiness step passed on Linux. Every final command ran with pinned Elixir **1.18.5** and OTP **28.5.0.7**, local Hex caches, and a PATH verified to contain no `rg`. The CI step used `MOJENTIC_MIX=mix scripts/verify-readiness-contract` with the pinned `mix` on PATH.

| Check | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e7b9998c52d3e96b8213e7cf881531a660d62103ebe98768902085128a77a958` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `a810b4a4aedae77b2cca98d8c9ee3d664832260b969831c10aa299ffcc829ba0` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `d16beaefa2a57f505da4fe72a77c206277a93f51d02b23998e3fc32e232b8d3d` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `6436a76f6c9f215476e71c23607008bfa1b717cb8c20c2fb6b07f4625ac5e6ce` |
| `scripts/verify-first-token-contract` | 0 | `4f3732bc3940ee2962abfed43b17313f7e13f2d759d995c4976899a24ad24f07` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `62d2dd2935037a71adce0ffe7e7c86f79bbf2b137e030c401451a5b60c87f164` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-packaged-first-token` | 0 | `53538c3808f5237c9a6e2c954e853d64385be6682ef74c9b863cbff7a9da2763` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MOJENTIC_MIX=mix scripts/verify-readiness-contract` | 0 | `563368d6b211b7d04e5ec9e36aaa377c79a91fee6668ed814ae026598d7f2812` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.audit` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.outdated --all` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MIX_ENV=dev scripts/recovery-mix docs` | 0 | `ab5b706a8fa973ebafbc53529e50750460b2e531878bf4d3787a7c20487edaf3` | `12f66072abf2e3ab2e2875f9eda10da6690da37c1875e8cbc8afcf2fc0276f7f` |
| `scripts/recovery-mix dialyzer` | 0 | `fe88dca27107e56c768d11e0d7845e3b1a78bc57200eb5a58a238d3810824235` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

| Suite | Result |
| --- | --- |
| test | 22 doctests, 6088 tests, 0 failures; zero Finch connection attempts |
| first-token-contract | 864 tests, 0 failures; zero Finch connection attempts |
| readiness-contract | 5523 tests, 0 failures; zero Finch connection attempts |
| packaged-first-token | 5523 tests, 0 failures; zero Finch connection attempts |
| ci-readiness | 5523 tests, 0 failures; zero Finch connection attempts |

Coverage: `91.40% | Total` (required threshold: 80%).

Local Hex payload: version **3.0.0**, SHA-256 `38b0a04f409b5aaa1bd49c598a31fe619095a70d2b1bec53ce4b3baf0d047014`. The fresh consumer checked extracted provider inputs and copied contract inputs, compiled the provider from that payload and verified its loaded ReqClient path. No package was published.

Dialyzer passed with zero errors; strict Credo found no issues. Hex outdated is informational and exited 1 for available upgrades; dependencies and advisory suppressions are unchanged. Dependency audit reported no vulnerabilities; Hex audit reported no retired or security-advisory packages in the local registry. Documentation built with existing missing links to `LICENSE`, `../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`. Sobelow passed with its existing missing-router diagnostic for this non-Phoenix library and quoted-key parsing warnings from the unchanged lockfile. Initial compilation of unchanged third-party development dependencies also emitted their existing deprecation warnings; project warnings-as-errors compilation and strict Credo passed.

## Execution identity and finalization

Execution-tree SHA-256: `7ca75b88bf60909cfa7750e6585aed804dc3bd23bdc676fd2d0546cde9e0f45e`. This hashes sorted path/digest records under `lib/`, `test/`, `scripts/`, `.github/workflows/`, plus `mix.exs`, `mix.lock`, `.formatter.exs` and `.hone-gates.json`; living evidence prose is excluded.

Base commit `169b741f93616d095352c429c3f57ab151deeba5` plus this execution identity identifies both provider and consumer verification. All changes remain uncommitted for Foundry. GitHub Actions was not monitored; these are local verification results.
