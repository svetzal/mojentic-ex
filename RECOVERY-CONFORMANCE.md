# Completion recovery conformance: Elixir streaming increment

This increment retains the delivered non-streaming recovery at
`a985c7b7303cecd0b864f697f8a4099b2e1522d9` and adds opt-in streaming recovery
under TRANSIENT-RECOVERY-2026-10.md and RECOVERY-REQUEST-2026-10.txt sections 1–5.
Recovery-disabled adapters retain their existing parsers, timeout behavior and
payloads. No dependencies, runtime pins, ordinary completion parsing, embeddings,
realtime, model management, tool depth, release files or sibling repositories
were changed in that historical increment. The c11 section below implements
the separate opt-in exact wire trace increment.

The c9 sections below describe the preserved implementation and its historical
validation. Their original capture files are absent from this worktree; log
references in those sections are historical, not fresh executable proof. The
c10 sections are also historical; the c11 section records this run's actual
commands and outcomes.

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

Historical correction: the omitted `pull --rebase origin main` was incorrectly
attributed to supplied instructions prohibiting the attempt. The c11 run actually
attempted it and recorded the filesystem denial below. The historical fetch alone
did not establish pull/rebase synchronization or conflict resolution. Final synchronization and landing on main remain external Foundry
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
trace hooks are opt-in at the default ReqClient boundary and retain encoded
request bytes independently of response observation. Lifecycle counts and masked
IDs do not substitute for exact evidence. Deterministic fixture equality verifies the semantic payload;
it does not establish provider-side idempotency or remote termination.

## Type-analysis prerequisite correction (c10)

This correction starts at `3f1bb3f9ed5aecd203b50ce32a07e8eaace6ad0f`.
The initial worktree was clean. Historical c9 validation described successful
runs but its capture files were absent here; those reports are not fresh proof.
The obsolete rejecting-log claim above has been replaced with that distinction.

Before edits, actual `git fetch origin` failed with exit **255** because the
worktree's external Git metadata/FETCH_HEAD is read-only (`fetch.log`).
Historical correction: `pull --rebase` was omitted, and the stated instruction-based
justification for omitting the requested attempt was incorrect. The actual c11
attempt and filesystem denial are recorded below.
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

At the end of c10, **exact wire trace hooks remained unverified**. Public completion
conformance and successful type analysis alone did not establish that capability, remote
termination, provider-side idempotency or live-model results.

`.foundry/validate-proof.py` validates the proof JSON shape, field types, complete
log existence, actual exit sidecars, successful project analysis, quality-gate
results, unchanged existing dependencies, AGENTS.md, test sources, HEAD and refs.
Its captured output is `proof-validation.log`. Source/configuration changes remain
in the working tree for Foundry review and finalization.


## c11: opt-in per-wire exact evidence

This correction starts at `04bee5c46a4728e148c75533710abf0c6935dc35`.
The initial status was clean. AGENTS.md, locked dependencies, runtime pins,
release files and all refs are preserved. Foundry owns Git finalization; edits
remain in this isolated worktree's task branch rather than landing via a commit,
PR or release during execution.

Before source edits, `git fetch origin` exited **255** and the actually attempted
`git pull --rebase origin main` exited **1**: both could not open the external
read-only FETCH_HEAD. [Complete synchronization output](.foundry/logs/synchronization.log)
records the execution denial and statuses. Neither operation established
synchronization or reached conflict handling. The historical claims that supplied
instructions prohibited the omitted pull were incorrect; they are corrected above.

`CompletionRequest` continues to own ordinary/structured recovery, `StreamRecovery`
continues to own stream recovery, and `ReqClient` captures the actual HTTP evidence.
`recovery: [trace_observer: callback]` enables the callback for all three providers,
all four completion APIs and broker/session propagation. Raw request bodies are
already encoded binaries; response chunks are observed before provider parsing,
including non-2xx bodies and partial ordinary responses. Events carry the exact
unmasked logical request ID, distinct attempt ID and wire number used by lifecycle
metadata. Callback errors terminate with safe `capture_failed`, disable resends,
and prevent successful session finalization or executing captured tool calls.
No dependency upgrades, admission/payload/parsing changes or generation timeout
were added. Traced ordinary requests use the existing idle receive-timeout contract.

Capture has explicit limits: supplied request headers rather than every generated
transport header; Req-exposed binary chunks rather than TLS/HTTP transfer framing;
no truncation or storage limit; caller-owned persistence. End events distinguish
available headers/empty data from unavailable evidence. Stream parser termination
reports `consumer_halted` instead of claiming EOF. Request capture occurs at the
authorized dispatch, before waiting for response headers; cancellation after
server receipt retains the independently captured request even without a response.
Cancellation kills blocked
capture workers and does not guarantee a terminal trace callback. Observer failure
can itself leave a partial trace. Missing evidence is never reconstructed or fetched
via another inference. See [migration/API guide](guides/streaming.md#opt-in-exact-http-evidence)
and `Mojentic.LLM.Recovery` for event fields and callback return requirements.

### Behavioral proof and concrete cases

The preserved c11 increment added the real-boundary streaming capture and
capture-failure regressions listed below. The current c12 behavioral proof and
fresh validation artifacts are documented in the final section; historical c11
counts are not used as evidence of this worktree's current behavior.

The following generated test names use the provider's full Elixir module name in
actual ExUnit output; each matrix includes OpenAI, Ollama and OMLX:

| Concrete test family | Evidence |
| --- | --- |
| `Elixir.Mojentic.LLM.Gateways.OpenAI complete exact trace retry_success preserves wire bytes and identity` | Ordinary and structured APIs, 503 then success; exact unchanged encoded request bodies, observed response bodies/status/headers, ordered distinct attempt identities and lifecycle correlation |
| `Elixir.Mojentic.LLM.Gateways.Ollama complete_object exact trace exhaustion preserves wire bytes and identity` | Final HTTP failure bodies from both attempts; same logical identity and exact request/response bytes |
| `Elixir.Mojentic.LLM.Gateways.OMLX complete exact trace malformed preserves wire bytes and identity` | Malformed body retained before decoding; no resend and safe default error/log/event serialization |
| `Elixir.Mojentic.LLM.Gateways.OpenAI events exact streaming trace partial retains observed chunks` | Both stream APIs retain exact partial chunks before interruption, one actual request and no replay |
| `Elixir.Mojentic.LLM.Gateways.Ollama legacy exact streaming trace malformed retains observed chunks` | Provider parsing failure retains observed raw chunk bytes independently of parsed output |
| `Elixir.Mojentic.LLM.Gateways.OMLX events exact streaming trace terminal_capture_failure retains observed chunks` | Terminal capture failure cannot become success or lose already observed/delivered progress |
| `Elixir.Mojentic.LLM.Gateways.OpenAI complete exact trace distinguishes unavailable response evidence` | All ordinary/structured providers distinguish unavailable evidence, empty body and interrupted partial body |
| `ordinary complete_object exact trace cancellation during_capture preserves dispatch accounting` | Ordinary/structured capture cancellation and cancellation before dispatch; monitored workers, zero-attempt pre-dispatch accounting |
| `Elixir.Mojentic.LLM.Gateways.Ollama events exact trace cancellation before_dispatch is authoritative` | Both stream APIs, all providers; no capture or request before dispatch, blocked capture killed on cancellation |
| `exact trace observer throw cannot report success or resend` | Non-`:ok` return, throw, exit and exception sanitized; observer failure cannot authorize another wire request |
| `Elixir.Mojentic.LLM.Gateways.OMLX session forwards exact trace and prevents tools on capture failure` | Broker and session streams reject terminal capture failure after completed tool evidence; no tool execution or successful session finalization |
| `Elixir.Mojentic.LLM.Gateways.OpenAI ordinary broker exact trace capture failure prevents tool execution` | Ordinary broker/session propagation includes exact request/response evidence without tool execution |

Existing real-boundary tests continue to assert sentinel absence from default
errors, JSON/history, lifecycle events, logs and broker tracer records. Explicit
trace callbacks alone retain raw request/response/credential evidence. Full
concrete names and byte/identity cases are in [wire-matrix.log](.foundry/logs/wire-matrix.log).


## Wire-boundary correction of preserved c11 (c12)

HEAD remains `d04f4325d053e39f4ead00afeeb05949fcc6b2f0`. This correction extends
that exact-tracing increment; it does not replace it. `AGENTS.md`, the source
requirements, runtime pins, versions and locked dependencies are preserved.
Fetch was attempted twice and returned **255** because the shared Git
`FETCH_HEAD` is read-only ([captured result](.foundry/logs/git-sync.log)).
`pull --rebase origin main`, commits, main landing and ref writes were not
attempted: this Foundry run expressly prohibits them and owns finalization.
There is no PR, release, live-model call, benchmark or sibling/harness edit.

### Public errors, progress and exact dispatch evidence

Recovery-only ReqClient metadata retains received non-2xx status and headers,
actual partial body bytes and the interrupted read cause. Public classification
and policy continue to use the HTTP status, so a truncated 401 cannot become a
retryable transport failure. Tracing-disabled recovery preserves the same safe
status/header/progress evidence without calling a trace observer. Raw trace
chunks remain exact and opt-in. Cancellation and capture failure remain terminal.
Legacy streaming status-only results and unrelated POST transport errors retain
their existing contracts; GET binary-body characterization is unchanged.

Request capture runs at authorized dispatch before the blocking response read.
Cancellation after actual server receipt therefore retains encoded body and
supplied header evidence with the real logical/attempt identities even without
response headers. A retry has a distinct attempt ID and the same request bytes.
Undispatched cancellation still has zero attempts and no trace. Killed or failed
capture callbacks can leave an incomplete prefix and need not produce a terminal
notification. Local cancellation still does not prove remote termination.

### Behavioral proof and deterministic assertion coverage

[proof.json](.foundry/proof.json) records
`dispatched cancellation before headers retains exact request and lifecycle identity`.
The rejecting probe exited **2**: the server received the complete request but
there was no request trace after cancellation. The corrected probe exited **0**
with concrete encoded body/header comparisons and actual lifecycle/error IDs.
The corresponding complete [rejecting](.foundry/logs/rejecting.log) and
[corrected](.foundry/logs/corrected.log) logs are retained.

The non-2xx boundary was also exercised against the preserved ReqClient before
restoring the correction ([rejecting matrix](.foundry/logs/status-rejecting.log),
exit **2**). It exposed transport/client-timeout classification and missing body
progress after receipt of a status. That initial expanded run also exposed an
incorrect test expectation for the public tuple-valued Retry-After; this was
corrected to the existing public type, with no production type change. The
in-progress trace-state refactor also exposed a stale `started` map field in
that run; it was removed before the corrected matrix.
The corrected status matrix exits **0** for all **96** selected cases
([log](.foundry/logs/status-corrected.log)).

All new provider cases use real ReqClient sockets through the public gateway APIs,
with no HTTP mocks. Matrix rows cover OpenAI, Ollama and OMLX, ordinary completion,
structured completion, terminal-event streaming and legacy streaming:

| Concrete test name | Assertions |
| --- | --- |
| `Elixir.Mojentic.LLM.Gateways.OpenAI complete interrupted 401 closed tracing false retains HTTP evidence without transport retry` | One actual request even with transport retries/admission enabled; numeric status, validated request ID, Retry-After, exact partial raw bytes, HTTP policy restriction, error/history/lifecycle identity and default privacy |
| `Elixir.Mojentic.LLM.Gateways.OMLX events interrupted 503 timeout tracing true retains HTTP evidence without transport retry` | Connection closure and stalled body reads, tracing on/off; exact received headers and partial trace data, failed end with available evidence, body-read phase; caller status restriction prevents resend |
| `Elixir.Mojentic.LLM.Gateways.Ollama complete_object dispatched attempt 2 cancelled before headers retains exact independent request evidence` | Initial/retry cancellation after server receipt and before headers; encoded body and supplied header comparisons, concrete UUIDs correlated to lifecycle/error/history, distinct retry ID, immutable retry bytes, no response evidence for cancelled attempt and no later request |
| `Elixir.Mojentic.LLM.Gateways.OpenAI legacy interrupted 503 retries only as admitted HTTP status with immutable bytes` | Positive HTTP-only retry after an interrupted error body; explicit admission sees exact safe progress, two actual identical requests, distinct attempt IDs and HTTP status in both history entries |
| `legacy non-2xx stream metadata true retains immediate status-only contract` | Recovery-disabled metadata/non-metadata streams retain their existing immediate status errors without reading an incomplete body |
| `unrelated post with retries disabled retains transport-only interrupted response` | A non-recovery POST continues returning its existing Req transport error |

The inherited exact-trace, zero-attempt cancellation, terminal capture failure,
privacy, immutable payload, broker/session and tool-safety regressions remain
part of the full suite. No exclusions, thresholds, dependencies, runtime pins,
advisory suppressions or capability limits were changed.

### Fresh validation on the pinned runtime

The [runtime log](.foundry/logs/runtime.log) verifies **Elixir 1.18.5 /
OTP 28.5.0.7**. Missing dependencies were provisioned only from the existing
lock ([provisioning log](.foundry/logs/provisioning.log), exit **0**).
The following actual outcomes replace the historical c11 validation table.
Commands execute through `foundry capture --`; `scripts/recovery-mix` selects and
verifies the pinned runtime. Complete captured stdout/stderr and actual exits
are indexed in [check-results.json](.foundry/check-results.json).

| Command after `foundry capture --` | Exit | Complete log |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | [format](.foundry/logs/format.log) |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | [compile](.foundry/logs/compile.log) |
| `env MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` | 0 | [test-compile](.foundry/logs/test-compile.log) |
| `scripts/recovery-mix credo --strict` | 0 | [credo](.foundry/logs/credo.log) |
| `scripts/recovery-mix test` | 0 | [test](.foundry/logs/test.log) |
| `scripts/recovery-mix test --cover` | 0 | [coverage](.foundry/logs/coverage.log) |
| `scripts/recovery-mix dialyzer` | 0 | [dialyzer](.foundry/logs/dialyzer.log) |
| `scripts/recovery-mix deps.audit` | 0 | [deps-audit](.foundry/logs/deps-audit.log) |
| `scripts/recovery-mix hex.audit` | 0 | [hex-audit](.foundry/logs/hex-audit.log) |
| `scripts/recovery-mix sobelow --config` | 0 | [sobelow](.foundry/logs/sobelow.log) |
| `scripts/recovery-mix docs` | 0 | [docs](.foundry/logs/docs.log) |
| `scripts/recovery-mix hex.outdated --all` | 1 | [outdated](.foundry/logs/outdated.log) |
| `scripts/recovery-mix test test/mojentic/llm/recovery_wire_test.exs test/mojentic/llm/stream_recovery_wire_test.exs test/mojentic/http/req_client_test.exs --trace` | 0 | [wire-matrix](.foundry/logs/wire-matrix.log) |
| `scripts/recovery-mix test test/mojentic/llm/recovery_wire_test.exs --only dispatch_boundary_proof` | 0 | [proof-final](.foundry/logs/proof-final.log) |

The full suite and coverage run both pass **22 doctests and 1,577 tests**, with
**19 exclusions** unchanged. Coverage is **89.16%**, above the unchanged **80%**
threshold. The final real-wire/ReqClient matrix passes **652 tests**. The final
before-headers proof runs one selected test successfully, with the other 436
cases excluded only by its `--only dispatch_boundary_proof` selection.
Credo reports no issues; Dialyzer reports zero errors and zero skips.

MixAudit reports no vulnerabilities. Its automatic database pull still emits a
read-only `FETCH_HEAD` denial, but independent read-only
[local](.foundry/logs/advisory-local.log) and
[upstream](.foundry/logs/advisory-remote.log) checks both return
`935abf7410a2bbb18e12579dee6e31267c3ed244`, verifying database freshness without
editing its checkout. Hex audit reports no retired/security-advisory packages.
`hex.outdated --all` returns **1** for available upgrades, an informational
result; no advisory or dependency upgrade was required by these audit results.
Sobelow completes successfully and warns that this library has no Phoenix router;
its existing lockfile keyword warnings are retained in the log. Documentation
builds successfully with the pre-existing missing LICENSE and igniter usage-rules
link warnings, outside this correction's scope.

Intermediate outcomes are retained: the initial request proof and status
characterization exited **2**, the first expanded wire run exited **0**
([log](.foundry/logs/wire-initial.log)), and Credo initially rejected added
complexity with exit **8** ([log](.foundry/logs/credo-rejected.log)). Cause extraction
was refactored without suppression; every required project gate was then run
successfully on the final source. The existing supported capability limits,
privacy defaults and tool/session safety tests remain intact.

[Evidence validation](.foundry/logs/evidence-validation.log) checks the exact proof
JSON shape and field types, nonzero rejecting/zero corrected exits, byte-complete
capture logs, all actual gate results, pinned runtime, advisory freshness,
unchanged protected files/HEAD and a nonempty, whitespace-clean working tree.
Changes remain uncommitted for Foundry review and finalization.
