# Offline verification

## Tested revision and scope

This correction tests base commit
`067831fbcd69c4b95567504db50ecf5d294a0e6e` plus the uncommitted changes in this
worktree. A read-only `git ls-remote origin refs/heads/main` check confirmed that
remote `main`, local `main` and this worktree identify that commit; no ref update
was needed.

The crash-handler regression now orders handler failure before normal gateway
completion. Public APIs, production behaviour, dependencies, runtime pins,
versions and CI wiring are unchanged. Foundry owns Git finalization; no commit,
push, merge, rebase, release or ref update is performed. Only this worktree is
edited.

## Concurrent outcome ordering

**solve returns error when an event handler crashes** uses a supervised gateway
task that announces its worker and callback PIDs, then waits for an explicit
release message before returning `DONE`. The solver also runs under the test
supervisor. The test requires the existing handler-error result from public
`solve/2` and the existing `HandlerErrorEvent` assertion before releasing normal
completion. It monitors the blocked callback before release and requires its
actual `:normal` exit. Supervisor shutdown also terminates pending tasks on test
failure; the gateway callback awaits that supervised task, so it cannot remain
blocked on a lost release. Receive and task-await timeouts bound failures only.
No sleep, clock advance, live service or socket participates.

The complete file passed seed **55772** and seeds **1–20**, each with **22 tests,
0 failures**. The complete agent directory passed seed **55772** with **99 tests,
0 failures**. All runs reported zero Finch connection attempts.

All nine files in `test/mojentic/agents/` were reviewed for competing concurrent
outcomes. Aggregator waiters register through explicit receive-trace barriers
before event delivery; their zero-time timeout case never supplies the missing
event. Concurrent AsyncLLMAgent requests assert every result independently.
Recursive event-flow assertions select the expected messages without depending
on callback arrival order; negative emitter assertions already wait for callback
exit barriers. The other agent files exercise synchronous results. No additional
instance of competing terminal outcomes without explicit ordering was found.

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
deterministic cases run on both sides. The readiness manifest now also identifies
the ordered crash-handler regression; scheduler, runner, shared helper and clock
inputs remain unchanged.
Root contract text and binding 3.0.0 decisions are unchanged. No sibling
repository or running-service boundary changed.


| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `10f3f7902bf9f924f660ad6ae51762ae6e126a0953ad31e6e1fd15dc35b28f32` |
| `test/contracts/readiness_v1.manifest.sha256` | `bbf7cb82ce53cc5eb126c31141dfddb327becb69a755fb7cc7e697b3647d2c90` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `9937b6e62b488e63c7c7614f87d69a604ae0496ec14ddfe9d666b5c4a43d1468` |

## Final local verification

All nine `.hone-gates.json` gates and the exact CI readiness step passed on Linux.
Every command ran with pinned Elixir **1.18.5** and OTP **28.5.0.7**, local Hex
caches, `MIX_ENV=test` (except documentation in `dev`), and a PATH checked to
contain no `rg`. A private command directory exposes host Linux utilities while
omitting ripgrep; runtime pins and repository scripts are unchanged. The CI step
used `MOJENTIC_MIX=mix scripts/verify-readiness-contract` with the pinned `mix` on
PATH. Full command output was captured; hashes identify the archived logs.

| Check | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `a810b4a4aedae77b2cca98d8c9ee3d664832260b969831c10aa299ffcc829ba0` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `23298dff40818c2aa55692e47e5a4311f604345b8bc55020a3c0ebf016f4ec4b` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `6436a76f6c9f215476e71c23607008bfa1b717cb8c20c2fb6b07f4625ac5e6ce` |
| `scripts/verify-first-token-contract` | 0 | `216092de73e04e40913219e0ae052e0ba1931ce79ae6f0ed03a01978d286af15` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `3ca2b88ec76d337a52a120ed0d0c9b683c07ad3de9834628c9e84eef44b9a859` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-packaged-first-token` | 0 | `b23a7155d48b6b6fa2d0c096054f95ea84da2c02f5e35578a6611c7130cd3dc9` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MOJENTIC_MIX=mix scripts/verify-readiness-contract` | 0 | `8b1d358d0f3329a3ea8c076d005d1c7f22b06dc7e35d909a97ea8a460cc699b9` | `860c43e709e040609b8e879afd668272693503083ca651adb5d0b40a4b31de0c` |
| `env MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.audit` | 0 | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix hex.outdated --all` | 1 | `e9296e2eee096a9e9dede088c128638ec21e305962aea3e6ce7737f7335e42b3` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `env MIX_ENV=dev scripts/recovery-mix docs` | 0 | `f7d8d276b20c5228780bc479ae5cea7429bb090c461aa6fc1ee099db99b953d7` | `12f66072abf2e3ab2e2875f9eda10da6690da37c1875e8cbc8afcf2fc0276f7f` |
| `scripts/recovery-mix dialyzer` | 0 | `3f3e0873af607906bc5567137625f138cf9697e0313ec1c4b8b0f2168de1d98e` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

| Suite | Result |
| --- | --- |
| test | 22 doctests, 6088 tests, 0 failures; zero Finch connection attempts |
| first-token-contract | 864 tests, 0 failures; zero Finch connection attempts |
| readiness-contract | 5523 tests, 0 failures; zero Finch connection attempts |
| packaged-first-token | 5523 tests, 0 failures; zero Finch connection attempts |
| ci-readiness | 5523 tests, 0 failures; zero Finch connection attempts |

Coverage: **91.40%** (required threshold: 80%). The 21 seeded file runs and complete
agent-directory run also passed with no Finch connection attempts. Their combined
stdout SHA-256 is
`9e4a2bff1bfb916505f76723665da1949579d89a93c9b9e7aa59fe19a8d5833a`.

Local Hex payload: version **3.0.0**, SHA-256 `38b0a04f409b5aaa1bd49c598a31fe619095a70d2b1bec53ce4b3baf0d047014`.
The fresh consumer verified the extracted provider inputs and copied consumer
contract inputs, compiled the provider from the payload and verified its loaded
ReqClient path. Both source and fresh payload consumers passed **ex-readiness-v1**
with manifest SHA-256
`bbf7cb82ce53cc5eb126c31141dfddb327becb69a755fb7cc7e697b3647d2c90`.
No package was published.

Dialyzer passed with zero errors; strict Credo found no issues. Dependency audit
reported no vulnerabilities. Hex audit reported no retired packages. Hex outdated
is informational; its exit status above reports available upgrades. Dependencies
and advisory suppressions are unchanged. Documentation built with existing missing
links to `LICENSE`, `../RELEASE-3.0.0.md` and `deps/igniter/usage-rules.md`. Sobelow
passed with its existing missing-router diagnostic for this non-Phoenix library
and quoted-key parsing warnings from the unchanged lockfile. Initial compilation
of unchanged third-party development dependencies emitted existing deprecation
warnings; project warnings-as-errors compilation and strict Credo passed.
The CI readiness run also emitted two bare `Logger - error:` diagnostics on
stderr; it exited zero with 5523 tests, zero failures and zero Finch connection
attempts. The captured output does not identify their cause.

## Execution identity and finalization

Execution-tree SHA-256:
`dc9cb432eec5731adf450d5039d469f847da6a7bcf9d6078af6730f4e9dbc164`.
This hashes sorted path/digest records under `lib/`, `test/`, `scripts/`,
`.github/workflows/`, plus `mix.exs`, `mix.lock`, `.formatter.exs` and
`.hone-gates.json`; living evidence prose is excluded.

Base commit `067831fbcd69c4b95567504db50ecf5d294a0e6e` plus this execution identity
identifies both provider and consumer verification, including the exact CI step.
All changes remain uncommitted for Foundry. GitHub Actions was not monitored;
these are local verification results.
