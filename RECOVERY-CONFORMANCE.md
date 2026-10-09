# Completion recovery conformance: Elixir streaming increment

This increment retains the delivered non-streaming recovery at
`a985c7b7303cecd0b864f697f8a4099b2e1522d9` and adds opt-in streaming recovery
under TRANSIENT-RECOVERY-2026-10.md and RECOVERY-REQUEST-2026-10.txt sections 1–5.
Recovery-disabled adapters retain their existing parsers, timeout behavior and
payloads. No dependencies, runtime pins, ordinary completion parsing, embeddings,
realtime, model management, tool depth, release files or sibling repositories
were changed. Exact raw wire trace hooks remain a separate increment.

The c9 sections below describe the preserved implementation and its historical
validation. Their original capture files are absent from this worktree; log
references in those sections are historical, not fresh executable proof. The
c10 evidence at the end records this run's actual commands and outcomes.

## Synchronization correction (c9, historical)

This validation correction starts exactly at preserved streaming increment
`207d791961ed9565d21487ae8218925297105691`. The initial worktree was clean.
Before synchronization, its binary diff and AGENTS.md were saved in `.foundry/`;
AGENTS.md remains byte-for-byte unchanged, including the release authorization.
This task explicitly prohibits releases and assigns Git finalization to Foundry.

An actual `git fetch --no-write-fetch-head --refmap= origin main` exited **0**
(`.foundry/logs/synchronization.log`). This is not a dry run: it contacts origin
and fetches objects while the empty refmap and no-write option preserve refs and
FETCH_HEAD. A separate `git ls-remote origin refs/heads/main` exited **0** and
reported `a985c7b7303cecd0b864f697f8a4099b2e1522d9`
(`remote-main.log`). HEAD and origin/main stayed unchanged.

`pull --rebase origin main` was not attempted because the later task restriction
explicitly prohibits rebasing and modifying refs. No execution denial for this
repository fetch occurred; no pull/rebase synchronization or conflict resolution
is claimed. Final synchronization and landing on main remain external Foundry
prerequisites. No commit, push, merge, rebase, tag or release was performed.

## Characterized boundaries and licensed changes

Before changing production source, the real Req fixture demonstrated that
OpenAI's terminal stream delivered partial content and then returned a legacy
request failure, without the required structured interruption/progress.
`OpenAILegacyStream` owns a suspended HTTP continuation; legacy Ollama repeatedly
enumerates its HTTP stream. `TerminalEventStream` owns one continuation and
requires provider terminal proof. oMLX shares the OpenAI parsers. Terminal APIs
supply no tools and suppress reasoning. Broker streaming accumulates completed
tools, executes them on stream completion, and normally logs then drops adapter
errors. ChatSession normally collects strings before finalization. Req normally
discards non-2xx headers and uses an absolute stream deadline. These paths remain
in place with recovery disabled; the existing suite characterizes compatibility.

Recovery-enabled adapters freeze the encoded body, endpoint and headers once,
then use `StreamRecovery` to own each HTTP continuation. Recovery reuses the
existing bounded admission/backoff policy. Streaming HTTP metadata retains
status, validated request ID and Retry-After, including after a partial-body
failure. Finch's streaming transport wrapper is classified at this boundary
without changing ordinary completion classification.

Observed semantic progress is counted before parsing/delivery. Delivered
progress is acknowledged with the recovery owner before returning the event to
the enumerator, so cancellation cannot lose already delivered content. Reasoning
suppressed by terminal APIs remains observed but undelivered. Keepalive bytes
increase only raw progress. Tool fragments are buffered; incomplete arguments
never become executable calls. Completed legacy calls are delivered once, but a
wire failure before terminal proof prevents broker execution. Once any semantic
output has been observed, retry eligibility cannot authorize replay.

A recovery worker owns only its request workers and owner monitor. Cancellation
covers connection/header waits, active streaming, admission and backoff. Consumer
halt and consumer process death close locally owned sockets and workers. Socket
closure does **not** establish remote inference termination. Active generation
has idle receive waits and no total generation deadline; recovery deadlines guard
new dispatch/admission/backoff rather than truncate an active generation.

The broker propagates opt-in errors and reasoning events. Follow-up recovery
never repeats a completed tool effect or resets tool depth. ChatSession's opt-in
`send_stream/3` records failed/halted status; `finalize_stream/1` returns the error
without adding a successful assistant response. Its accumulation handle must be
finalized to release the handle process, as with legacy session streaming.

Default broker payload tracing is suppressed for recovery-enabled streaming.
Lifecycle metadata, error inspection and JSON serialization omit request text,
response text, tool arguments, credentials and raw causes. Original causes remain
available only through `CompletionError.cause/1`. No unsafe observer is installed
by default.

## Proof first

Before changing production code, expanding documentation or running full gates,
six new public-boundary probes exercised the remaining completed-tool loss through
the production ReqClient and deterministic scripted TCP responses. The cases are
`#{gateway} #{entrypoint} retains fragmented completed tools before observation failure`,
for OpenAI, Ollama and oMLX, with `adapter` invoking `complete_stream/4` and
`broker` invoking `Broker.generate_stream/4`.

The first chunk delivers sentinel content and starts two tool argument fragments.
The test waits for actual delivery before releasing a second chunk containing both
argument suffixes, their completion marker, then `tool_calls: 7`. Each case asserts
exactly four observed fragments and two completed calls; zero delivered fragments
or completed calls; unchanged previously delivered content; actual raw bytes;
one server-observed wire request; no tool execution or successful terminal;
explicit protocol interruption; and matching progress and actual logical request
and attempt identities in the final error, history and failure lifecycle records.

The historical report described a failure with zero completed calls instead of
two, followed by a passing correction. Its rejecting and passing logs are absent
here, so those reported exit codes are not executable evidence for this run.
This correction retains all six probes; fresh execution is recorded below. The
current `.foundry/proof.json` verifies project type analysis directly.

Legacy streaming now observes and assembles each frame before advancing to the
next frame. A later observation exception retains already assembled completed
calls and fragment counts. Parsing remains atomic for chunk delivery, so none
of the failing chunk's tools or terminal events reach the adapter or broker.
Earlier acknowledged content remains delivered. EOF uses the same frame path;
terminal-event APIs retain their observation and parsing contract. Existing
parsing-failure, EOF, privacy, cancellation, payload and broker/session safety
regressions remain intact. Recovery-disabled behavior is unchanged.

## Named production-HTTP cases

`test/mojentic/llm/stream_recovery_wire_test.exs` uses the production ReqClient and
scripted TCP responses through public adapter, broker and session entrypoints.
The complete traced cases and results are in `.foundry/logs/stream-cases.log`.
The six-path matrix covers OpenAI, Ollama and oMLX `complete_stream/4` and
`complete_stream_events/3` independently.

| Named case suffix | Verified assertions |
| --- | --- |
| `recovers 503 with immutable full payload and exact lifecycle` | Complete server-observed request equality, messages, Retry-After delay, received headers, all eight lifecycle events and exact wire/logical IDs |
| `persistent failures preserve exact bounded identities and histories` | Three identical server requests, fifteen lifecycle events, three distinct attempt IDs, one logical ID and exact history correspondence |
| `partial content cannot replay or execute incomplete tools` | Exact raw bytes and observed/delivered progress; explicit interruption, original cause, one request and no successful terminal |
| `partial reasoning cannot replay or execute incomplete tools` | Delivered reasoning for legacy APIs; observed-only reasoning for terminal APIs; no replay |
| `partial tools cannot replay or execute incomplete tools` | Observed fragments, zero delivered fragments/calls, no execution/retry; terminal APIs preserve their intentional unexpected-tool protocol rejection |
| `keepalive bytes recover without semantic progress` | Nonzero raw bytes, zero semantic progress, two identical requests and complete lifecycle |
| `pending admission allow/reject is asynchronous and never counts as a wire attempt` | One request while pending; explicit allow preserves payload; reject prevents resend; exact lifecycle and identities |
| `ambiguous local failure requires admission by default` | Ollama/oMLX acceptance remains unknown and no second request is authorized |
| `cancellation during active/admission/backoff sends no subsequent request` | Original HTTP failure retained when present, cancellation evidence, exact phase-specific lifecycle and one server request |
| `cancellation after delivery preserves exact semantic and raw progress` | Delivered content acknowledged before cancellation, exact bytes and closed live socket |
| `Retry-After ceiling refuses resend and preserves original HTTP failure` | 429 and parsed delay retained; configured ceiling prevents a second request |
| `HTTP 400/401 cannot become retryable through caller selection` | Explicit status selection cannot bypass unsafe streaming failure classification |
| `consumer halt closes owned HTTP and recovery workers` | Public consumer takes one event; server observes socket closure and one request |
| `consuming process death closes its live socket` | Monitored consumer termination closes its server-observed socket without touching unrelated work |
| `recovery deadline is not a total active generation timeout` | Injected clock passes deadline during an active held request; successful release still completes with one request |
| `broker default tracing and lifecycle serialization exclude sentinel payloads` | No payload trace entries; sentinel request/response/credential values absent from errors, JSON, events and logs |
| `broker executes completed tool once then propagates follow-up interruption` | Exact tool arguments/result in follow-up payload, one execution, immutable retry payload, eleven lifecycle events and exact request/history identities across two semantic interactions |
| `session refuses to finalize partial output after a completed tool` | Concrete tool effect once, consumer receives failure, finalization returns that failure and original immutable history remains unchanged |
| `broker recovery does not replenish streaming tool depth` | One tool execution; recovered second completion still exhausts depth one |
| `completed tool deltas followed by wire failure expose progress without execution` | OpenAI/oMLX observed/delivered completed-call counts, exact bytes and no tool execution before terminal proof |
| `final frame without newline retains exact raw byte count` | Ollama legacy and terminal APIs accept the actual EOF frame without counting synthetic bytes |

Terminal-event APIs deliberately do not execute tools. Their unexpected-tool
error is the original parser failure; they stop at that failure rather than read
a later transport failure. Ollama's atomic final tool frame completes its legacy
request; completed-call followed-by-wire-failure is separately exercised for the
OpenAI-compatible protocols where terminal proof still requires `[DONE]`.

## Correction cases and public paths

All cases use scripted HTTP fixtures and the production `Mojentic.HTTP.ReqClient`.
No gateway mock or live-model request establishes this correction's evidence.

| Named case suffix | Public paths and assertions |
| --- | --- |
| `broker failing tool protects default observability without replay` | OpenAI, Ollama and oMLX `Broker.generate_stream/4`; one completed failing tool invocation, exactly two HTTP requests, unchanged user and tool-result messages, distinct logical follow-up identity, default logs/tracer records/safe error representations/lifecycle events exclude all sentinels |
| `legacy parser exception retains same-chunk semantic observations and bytes` | OpenAI `complete_stream/4`; content, reasoning and tool fragments before malformed arguments, exact 378 bytes, no delivered output, interruption and one failure history entry |
| `observation exception retains valid same-chunk semantics` | All three providers, `complete_stream/4` and `complete_stream_events/3`; valid content/reasoning/tool frames before malformed tool data, exact raw bytes and independently specified observed versus delivered progress, exact identities/history/lifecycle, no resend or successful terminal |
| `parser exception preserves previously delivered output` | All six completion paths; server releases malformed chunk only after public content delivery, exact cumulative bytes, prior content remains delivered while later reasoning is observed only, interruption/history/lifecycle retain progress |
| `legacy parsing exception preserves completed but undelivered tools` | All three `Broker.generate_stream/4` paths; valid completed tool frame before malformed arguments in the same chunk, one observed completed call and zero delivered/executed calls, exact raw bytes and no successful terminal |
| `retains fragmented completed tools before observation failure` | All three `complete_stream/4` and `Broker.generate_stream/4` paths; two calls assembled across held HTTP chunks, exact four fragments/two completions, preserved earlier delivery, zero tool delivery/execution, actual bytes, one request, protocol interruption and exact error/history/lifecycle identity correspondence |
| `EOF observation exception retains progress without synthetic bytes` | Ollama both completion APIs; malformed final frame without newline, prior content and applicable reasoning delivery retained, actual bytes only, one request and interrupted error |

Terminal-event APIs do not support tool execution; their malformed-frame cases
verify progress without adding that capability. Existing ordinary/structured
recovery, recovery-disabled adapter/broker tests, follow-up payload equality and
streaming tool-depth tests remain intact and are included in the full suite.

## Capability limits

`Recovery.capabilities/1` reports local request cancellation supported and remote
cancellation, request status and idempotency unsupported, with exact remote
termination unknown, for all three providers. Local ambiguity needs explicit
application admission. There is no model unload, tool/session replay, agent
restart, harness policy or live-model experiment in this increment. Exact wire
trace hooks remain unavailable and are not represented by lifecycle counts or
masked-ID evidence. Deterministic fixture equality verifies the semantic payload;
it does not establish provider-side idempotency or remote termination.

## Type-analysis prerequisite correction (c10)

This correction starts at `3f1bb3f9ed5aecd203b50ce32a07e8eaace6ad0f`.
The initial worktree was clean. Historical c9 validation described successful
runs but its capture files were absent here; those reports are not fresh proof.
The obsolete rejecting-log claim above has been replaced with that distinction.

Before edits, actual `git fetch origin` failed with exit **255** because the
worktree's external Git metadata/FETCH_HEAD is read-only (`fetch.log`).
`pull --rebase` was not invoked: the current Foundry instruction explicitly
prohibits rebasing and modifying refs, overriding earlier repository guidance.
No synchronization success or conflict resolution is claimed. HEAD, all refs
and AGENTS.md remain unchanged. Foundry owns finalization and landing on main;
no commit, push, merge, rebase, tag, release, sibling edit, live-model request or
benchmark restart was performed.

### Changes and actual type analysis

Added Dialyxir `~> 1.4` for development/test only, with `runtime: false`.
The lockfile adds only Dialyxir **1.4.8** and erlex **0.2.9**; every existing
locked dependency remains byte-for-byte unchanged. Core and project PLTs are
configured under `priv/plts/`, ignored by Git, and cached in CI with OS,
Elixir **1.18.5**, OTP **28.5.0.7** and lockfile identity. CI runs development
and test analysis; both release jobs require that gate. ExUnit is added to the
test PLT to analyze the existing compiled support assertions, without excluding
those modules. Local registry/NIF caches used by the existing runtime wrapper
are also ignored. No runtime dependency or runtime pin was upgraded.

The first real `mix dialyzer` analyzed compiled project modules and exited **2**
with **16** findings (`dialyzer-first.log`), rather than failing because the task
was absent. The corrections declare the tracer event struct union and its member
types, retain atomics handles as `:atomics.atomics_ref()` across the existing
reference guards through a typed accessor, and remove unreachable branches in
text-message sizing, delivered-progress fallback and the existing WebSocket
upgrade call. Text sizing is only called for binary-content constructors;
delivered progress is always a map; `WebSocket.new/4` receives unchanged empty
headers and cannot return success. The existing transport error remains unchanged;
this does not implement a WebSocket handshake. No completion behavior, recovery
policy, thresholds, exclusions or suppressions were changed.

Intermediate development analyses exited **2** with three then two remaining
findings; the next passed. Test analysis initially exited **2** with **12** findings
(including one built-in skipped warning), revealing absent ExUnit PLT entries and
an error formatter contract that omitted the already accepted `CompletionError`.
Adding ExUnit to the test PLT and that exact error type resolves these findings.
Final development and test analyses both exit **0**, with **Total errors: 0,
Skipped: 0, Unnecessary Skips: 0**, and `done (passed successfully)`.
No task absence, skip-analysis flags, ignored warnings, weakened type contracts,
advisory allowlists or threshold changes are used as acceptance evidence.

### Runtime and commands

Every Mix invocation uses the unchanged `scripts/recovery-mix` wrapper, which
checks the exact installed versions before running Mix. The default PATH's
Elixir 1.20.4 / OTP 29 was inspected but never used to run Mix in this correction.
The selected executable identities are:

- `/home/svetzal/.local/share/mise/installs/elixir/1.18.5-otp-27/bin/elixir`
- `/home/svetzal/.local/share/mise/installs/elixir/1.18.5-otp-27/bin/mix`
- `/home/svetzal/.local/share/mise/installs/erlang/28.5.0.7/bin/erl`

`runtime-version.log` records Mix **1.18.5** and running OTP **28**.
`runtime.log` records System.version(), running OTP release, `code:root_dir()`,
the installed OTP_VERSION **28.5.0.7**, and in-VM executable resolution (Erlang
resolves to that installation's `erts-16.4.0.6/bin/erl`). Elixir was compiled on
OTP 27 and executes on the pinned OTP **28.5.0.7**. Dependency sources and
artifacts were rebuilt here. The existing read-only Hex cache was copied into
worktree-local HEX_HOME before `deps.get`, which succeeded without updating
existing dependency versions. No global cache was edited.

All builds/tests were executed through `foundry capture -- …`. Complete stdout
and stderr are preserved, separately labelled, in `.foundry/logs/<name>.log`;
matching `.command` and `.exit` sidecars record the exact command and actual
capture process exit. Foundry's original separate capture files are also retained
in its tool-log directory. The table lists final evidence unless marked initial
or intermediate; earlier successful gate executions before the error-type
correction are retained with `-before-error-type` filenames.

| Exact captured command | Actual exit | Complete log under `.foundry/logs/` |
| --- | --- | --- |
| `foundry capture -- git fetch origin` | 255 | [fetch.log](.foundry/logs/fetch.log) |
| `foundry capture -- scripts/recovery-mix --version` | 0 | [runtime-version.log](.foundry/logs/runtime-version.log) |
| `foundry capture -- scripts/recovery-mix run --no-compile --no-start -e 'IO.inspect(System.version(), label: "Elixir"); IO.inspect(System.otp_release(), label: "OTP release"); IO.inspect(:code.root_dir(), label: "OTP root"); IO.puts(File.read!(Path.join([to_string(:code.root_dir()), "releases", System.otp_release(), "OTP_VERSION"]))); for executable <- ["elixir", "mix", "erl"], do: IO.puts("#{executable}: #{System.find_executable(executable)}")'` | 0 | [runtime.log](.foundry/logs/runtime.log) |
| `foundry capture -- scripts/recovery-mix deps.get` | 0 | [deps-get.log](.foundry/logs/deps-get.log) |
| `foundry capture -- scripts/recovery-mix dialyzer` | 2 | [dialyzer-first.log](.foundry/logs/dialyzer-first.log) |
| `foundry capture -- scripts/recovery-mix dialyzer` | 2 | [dialyzer-intermediate.log](.foundry/logs/dialyzer-intermediate.log) |
| `foundry capture -- scripts/recovery-mix dialyzer` | 2 | [dialyzer-second.log](.foundry/logs/dialyzer-second.log) |
| `foundry capture -- scripts/recovery-mix dialyzer` | 0 | [dialyzer-dev-before-error-type.log](.foundry/logs/dialyzer-dev-before-error-type.log) |
| `foundry capture -- env MIX_ENV=test scripts/recovery-mix dialyzer` | 2 | [dialyzer-test-first.log](.foundry/logs/dialyzer-test-first.log) |
| `foundry capture -- scripts/recovery-mix dialyzer` | 0 | [corrected.log](.foundry/logs/corrected.log) |
| `foundry capture -- env MIX_ENV=test scripts/recovery-mix dialyzer` | 0 | [dialyzer-test.log](.foundry/logs/dialyzer-test.log) |
| `foundry capture -- scripts/recovery-mix test test/mojentic/llm/stream_recovery_wire_test.exs --only completed_observation_proof --trace` | 0 | [completed-observation.log](.foundry/logs/completed-observation.log) |
| `foundry capture -- scripts/recovery-mix format --check-formatted` | 0 | [format.log](.foundry/logs/format.log) |
| `foundry capture -- scripts/recovery-mix compile --warnings-as-errors` | 0 | [compile.log](.foundry/logs/compile.log) |
| `foundry capture -- env MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | [compile-test.log](.foundry/logs/compile-test.log) |
| `foundry capture -- scripts/recovery-mix credo --strict` | 0 | [credo.log](.foundry/logs/credo.log) |
| `foundry capture -- scripts/recovery-mix test` | 0 | [test.log](.foundry/logs/test.log) |
| `foundry capture -- scripts/recovery-mix test --cover` | 0 | [coverage.log](.foundry/logs/coverage.log) |
| `foundry capture -- scripts/recovery-mix deps.audit` | 0 | [deps-audit.log](.foundry/logs/deps-audit.log) |
| `foundry capture -- scripts/recovery-mix hex.audit` | 0 | [hex-audit.log](.foundry/logs/hex-audit.log) |
| `foundry capture -- scripts/recovery-mix sobelow --config` | 0 | [sobelow.log](.foundry/logs/sobelow.log) |
| `foundry capture -- scripts/recovery-mix hex.outdated --all` | 1 | [hex-outdated.log](.foundry/logs/hex-outdated.log) |
| `foundry capture -- scripts/recovery-mix docs` | 0 | [docs.log](.foundry/logs/docs.log) |
| `foundry capture -- git -C /home/svetzal/.local/share/elixir-security-advisories-mirego rev-parse HEAD` | 0 | [advisory-local.log](.foundry/logs/advisory-local.log) |
| `foundry capture -- git ls-remote https://github.com/mirego/elixir-security-advisories.git refs/heads/main` | 0 | [advisory-remote.log](.foundry/logs/advisory-remote.log) |
| `foundry capture -- scripts/recovery-mix run --no-start -e 'config = YamlElixir.read_from_file!(".github/workflows/build.yml"); jobs = config["jobs"]; job = jobs["dialyzer"]; runs = Enum.filter(job["steps"], &Map.has_key?(&1, "run")); true = Enum.map(runs, & &1["run"]) == ["mix dialyzer", "mix dialyzer"]; true = List.last(runs)["env"]["MIX_ENV"] == "test"; for name <- ["release-build", "publish-hex"], do: true = "dialyzer" in jobs[name]["needs"]; for {_name, job} <- jobs, step <- Map.get(job, "steps", []), step["uses"] == "erlef/setup-beam@v1", do: true = step["with"] == %{"elixir-version" => "1.18.5", "otp-version" => "28.5.0.7"}; IO.puts("CI YAML parses; development/test Dialyzer gates, release prerequisites, and runtime pins verified")'` | 0 | [ci-config.log](.foundry/logs/ci-config.log) |

### Fresh conformance, audits and limits

Before expanding this report or running the full suite, development type analysis
was exercised through actual compiled project modules, its findings corrected,
and the passing analysis captured. `.foundry/proof.json` uses the required
**direct** shape: this objective establishes static analysis and CI prerequisites,
without a demonstrated completion/recovery behavior defect to repair. Its
acceptance command is successful project Dialyzer analysis, not task discovery.
Initial failed analyses are independently retained; they are not fabricated
behavioral rejections or historical rejecting logs.

The retained production-Req completed-observation probe passes all six cases
(**159 tests, 153 excluded, zero failures**). OpenAI, Ollama and oMLX public
`complete_stream/4` and `Broker.generate_stream/4` retain exact raw bytes,
fragmented completed calls, interrupted progress, zero tool execution and exact
history/lifecycle identities. Test files and fixtures are unchanged. Both final
full test executions pass **22 doctests and 1,337 tests**, zero failures, with
the existing **19 integration exclusions**. Coverage is **89.07%**, above the
unchanged **80%** threshold. Strict Credo reports no issues. Both project compile
commands succeed with warnings-as-errors; existing dependency deprecation
warnings during dependency builds are preserved in the initial capture logs.

MixAudit exits zero and reports no vulnerabilities. Its automatic advisory refresh
emits an actual read-only `.git/FETCH_HEAD` denial; that refresh did not succeed.
Independent read-only local and upstream-main checks both succeed at
`935abf7410a2bbb18e12579dee6e31267c3ed244`, establishing cache freshness for this
scan without mutating the advisory checkout. Hex audit finds no retired or
security-advisory packages. No advisory was suppressed or allowlisted.

Sobelow exits zero; this is not a Phoenix project. Its missing-router notice and
existing quoted-keyword lockfile warnings do not establish Phoenix security
coverage. `hex.outdated --all` exits **1** for available upgrades, an informational
result; existing dependencies were not upgraded. Docs builds successfully with
existing missing LICENSE and igniter usage-rule link warnings. The missing tracer
type-reference warnings are resolved. No precommit alias exists. Streaming,
broker and chat-session guides were reviewed against their retained contracts
and require no content changes. CI YAML is parsed by the installed YamlElixir
and its dev/test gates, release prerequisites and every runtime pin are verified;
GitHub-hosted CI execution is not claimed.

**Exact wire trace hooks remain unverified.** Public completion conformance and
successful type analysis do not establish exact wire trace capability, remote
termination, provider-side idempotency or live-model results.

`.foundry/validate-proof.py` validates the proof JSON shape, field types, complete
log existence, actual exit sidecars, successful project analysis, quality-gate
results, unchanged existing dependencies, AGENTS.md, test sources, HEAD and refs.
Its captured output is `proof-validation.log`. Source/configuration changes remain
in the working tree for Foundry review and finalization.
