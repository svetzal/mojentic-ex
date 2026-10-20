# Offline verification

## Tested revision and scope

This correction tests base commit
`ff478c46b6d4d2e16bd127fbf7e9c0161a72605e` plus the uncommitted scanner
portability, connection-verification and deterministic date-test changes. Foundry owns Git finalization;
no commit, push, release or ref update is performed. Production `lib/`, public
APIs, dependencies, runtime pins, versions and CI wiring are unchanged.

The exact CI readiness command was attempted first:
`MOJENTIC_MIX=mix scripts/verify-readiness-contract`. The fresh worktree initially
lacked dependencies, so Mix stopped before executing tests. Dependencies were
then installed for validation, without changing the lockfile. The exact command
was rerun with those dependencies present.

## Scanner regression

The scanner uses host `find` and `grep` instead of ripgrep. It retains the
existing forbidden-operation expressions, roots, scanner filename exclusion,
`.exs` timing-assertion scope and scripts-only registry-command scope. Whitespace
and command word boundaries use POSIX character classes. Rejection diagnostics
still include exact path, line number and source text. Grep execution errors
fail the scanner rather than being interpreted as no matches.

The command regression runs with a minimal PATH containing only bash, dirname,
find and grep. It retains all previous inert fixtures and adds indented commands,
command-prefix acceptance, filenames containing spaces and a missing-grep
failure check. No fixture executes a forbidden operation.

A negative control ran the updated minimal-PATH regression against the scanner
from the base commit. It failed on the first forbidden-operation fixture: the
old scanner printed three `rg: command not found` diagnostics but exited zero.
The replacement passes the same regression. This establishes the CI portability
failure independently of the developer host's installed ripgrep.

## Finch pool investigation

`Mojentic.HTTP.ReqClient.start_stream/4` starts a dedicated Finch pool supervisor
before constructing and dispatching each streaming Req request. Cancellation of
a blocked consumer can kill that linked supervisor, producing the logged
`Finch.Pool.Supervisor` entries with synthetic `127.0.0.1` endpoint identifiers.

The existing `Mojentic.TestSupport.ScriptedTransport` is an in-process Req adapter.
Its identifiers come from `System.unique_integer/1`, not bound ephemeral sockets.
Its responses and stream messages are delivered in process; it does not start an
HTTP server. The other transport regression also installs a custom Req adapter.
Both retain production request preparation, dispatch and observation.

Finch HTTP/1 pool initialization builds connection state with `mint: nil`.
Connection establishment occurs on pool request checkout, inside
`Finch.HTTP1.Conn.connect/2`, rather than when its supervisor starts. Both HTTP/1
and HTTP/2 emit `[:finch, :connect, :start]` at connection establishment.

The shared test helper now counts that event across the entire suite and fails
after the suite if any connection was attempted. It runs in source consumers,
the complete test suite and the fresh packaged consumer. A negative control
emitted one synthetic event without opening a socket: the test passed but the
suite guard correctly exited 1 with the connection-attempt diagnostic. A normal
adapter regression and all 863 first-token cases passed with zero attempts.
Pool startup/kill messages can therefore remain without indicating socket use;
removing the production pool lifecycle would change library code outside scope.

## Calendar test correction

A broader clock search also found two date-resolver tests outside the readiness
file set using the wall-clock fallback: omitted and invalid reference dates.
Those executions are replaced with exact year-boundary and leap-day assertions
using the existing `reference_date_in_iso8601` input. Library default-date
behavior is unchanged; the wall-clock fallback is no longer exercised by these
tests because the existing API does not inject that fallback clock. All remaining
date-resolver executions supply a valid fixed reference date.

## Remaining calendar-clock constraint

`test/mojentic/llm/tools/current_datetime_test.exs` still has nine executions of
`CurrentDatetime.run/2`, which unconditionally calls `DateTime.utc_now/0`.
The timestamp test also asserts a fixed 2020–2030 interval. There is no existing
clock injection point. Eliminating that clock dependency while retaining these
behavioral tests requires a library change, conflicting with this task's explicit
instruction to leave library code unchanged. Approval for an internal clock
injection point has been requested; until approved, the implementation and those
tests remain unchanged. Passing gates do not resolve this outstanding constraint.

## Shared executable contracts

Source public-API consumer/provider verification and fresh extracted Hex
consumer/provider verification execute the same **ex-readiness-v1** file set,
`test/contracts/readiness_v1.files`, at the revision identified above. Both check
the shared manifest; the fresh consumer also checks extracted provider files and
copied test inputs, compiles the local payload and verifies its loaded ReqClient
path. Only harness hashes changed; binding contract cases and root contracts
remain unchanged. No sibling repository or running-service boundary changed.

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `80141cf30a543b798d5818c29c1e8af9bd4d027345fbe312f064f23a8a5b8faf` |
| `test/contracts/readiness_v1.manifest.sha256` | `ab874851d9d6afb26b0f1c7f5dffc19ce473cb97066e6073951c528717363d5f` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `3228afd653a67b1c73fe3bbfa98921bd330499305cb43221b15b4706598fd56a` |

## Final verification

All nine `.hone-gates.json` commands pass. The final complete coverage rerun, after the calendar-test changes, passes **22 doctests and 6,084 tests**, with **91.40%** coverage (threshold 80%). Source and fresh packaged readiness each pass **5,395 tests**, and the first-token gate passes **864 tests**, with zero failures and zero Finch connection attempts in each suite.

| Gate | Exit | Stdout SHA-256 | Stderr SHA-256 |
| --- | --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `cad6b050bcbc6dd3b85a69c35e185f530c9ec7e6df0fd7580c14e749e5417cba` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix test --cover` | 0 | `f92b6e4be5db2ad0e2af1ab89afe0ef1efbabfa09117ca098deb38e01738c436` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `21cb799fb7d41faf903e8df55c9e8298b07e3999fe29e8d596b2eb0d700e4a6e` |
| `scripts/verify-first-token-contract` | 0 | `342c810e32c2702a61feb82dad861200e3e8ae85a269958e4c762d8543f80681` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-readiness-contract` | 0 | `70ffae750b771da4864dd938dd40e808b7dbb59f1f1971039c956a5c5ba9b0af` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-packaged-first-token` | 0 | `d7a7a8bf92aa804c031ab39d63c488f32edd1def36b5f12fbe9137676d5a5036` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

The local Hex payload is version **3.0.0**, SHA-256 `40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`. The consumer compiles that payload afresh and verifies its loaded provider path. It is never published.

Additional requested checks:

| Command | Exit |
| --- | --- |
| `scripts/recovery-mix dialyzer` | 0 |
| `env MIX_ENV=test scripts/recovery-mix dialyzer` | 0 |
| `scripts/recovery-mix hex.audit` | 0 |
| `scripts/recovery-mix hex.outdated --all` | 1 |
| `scripts/recovery-mix docs` | 0 |

The test-environment warnings-as-errors compile and the final format/compile/strict-Credo rerun also pass. Hex outdated is informational; no dependencies, runtime versions or advisory suppressions were changed. Existing Sobelow/non-Phoenix and documentation-link diagnostics remain visible in the captured output.

## Execution identity and finalization

Execution-tree SHA-256: `b34f1047dd01090be30fa4b163cfea5a7ef040fb717ae8f93d86993788387a5f`. This hashes sorted path/digest records for every file under `lib/`, `test/`, `scripts/`, `.github/workflows/`, plus `mix.exs`, `mix.lock`, `.formatter.exs` and `.hone-gates.json`. Living evidence prose is excluded.

The base revision and this execution identity identify both provider and consumer verification. Changes remain uncommitted for Foundry. No new GitHub workflow run or run ID exists for these uncommitted changes; confirming the pushed workflow remains a Foundry finalization step.
