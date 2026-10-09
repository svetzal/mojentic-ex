# Completion recovery conformance: Elixir bounded non-streaming recovery

This increment implements the Policy semantics and Admission sections of
TRANSIENT-RECOVERY-2026-10.md for ordinary and structured completion only.
Streaming recovery and exact wire trace hooks remain work for a later increment.
No live models, releases, sibling ports, harness edits, agent restarts, model
unloads, benchmarks, or tool replay were used.

## Synchronization correction

The earlier implementation missed the requested pre-coding pull/rebase attempt.
The previous conformance account incorrectly treated rebasing as inherently
prohibited. The correction plan supplies these actual formation outcomes:
fetch exited **0**; pull exited **1** because `FETCH_HEAD` was read-only. That
failed pull is not successful synchronization, nor evidence of a merge conflict.

For this Foundry worktree, the initial tree was clean at
`bff29cf28c9899ea5c1cafc6041bae5157d7c9cc`. Before source edits, `git fetch origin`
exited **0**. HEAD and fetched `origin/main` both resolved to that commit;
`git log HEAD..origin/main` was empty. There were no subsequent arrivals to
reconcile and no conflicts. This run's final user requirements expressly prohibit
rebase and ref modification and give Foundry finalization ownership, so this run
did not execute pull/rebase, commit, push, tag, release, merge or create a PR.
The supplied prior failed pull is distinguished from this run's executed fetch.
The coordinator's AGENTS.md guidance is preserved.

## Boundary characterization and licensed changes

All six adapter paths use `CompletionRequest.run/8`: OpenAI, Ollama and OMLX
`complete/4` and `complete_object/4`. The semantic body and HTTP headers are
constructed once, before recovery. Only opt-in recovery scheduling and error
history change under the contract's Policy semantics and Admission sections and
request sections 2–3. `recovery: nil` still calls the original parser and HTTP
client directly. Existing successful parsing, provider payload adaptation,
legacy errors and one-attempt failure evidence are preserved.

Broker tool recursion calls a new completion after executing tools; the recovery
loop encloses only that completion, never the broker loop. Its tool-depth counter
is outside recovery. ChatSession prepares history before calling Broker and
appends an assistant response only on success. Its token/interaction accounting
remains outside recovery. Existing Message has no native reasoning-history field;
recovery preserves the entire adapted wire payload without inventing one.
Tests retain existing parser-specific reasoning behavior.

## Migration and options

```elixir
alias Mojentic.LLM.{Broker, CompletionConfig, CompletionError, Message}
alias Mojentic.LLM.Gateways.Ollama

config = CompletionConfig.new(recovery: [
  max_attempts: 3,
  base_delay: 100,
  delay_ceiling: 30_000,
  budget: 60_000,
  admission: fn context ->
    # Ask the application admission service. This message alone is not approval.
    send(admission_service, {:check_completion, context})
    :pending
  end,
  observer: &IO.inspect/1
])

case Broker.generate(Broker.new("local-model", Ollama), [Message.user("Hello")], nil, config) do
  {:ok, text} -> text
  {:error, %CompletionError{} = failure} -> CompletionError.safe_metadata(failure)
end
```

The admission service resolves a pending context with
`send(context.reply_to, {:recovery_admission, context.ref, :allow})` or `:reject`.
The callback may also return `:allow` or `:reject` immediately. It runs in a
monitored worker; callback failure rejects admission. No pending decision times
out into approval. No-hook local recovery requires acceptance `:no` (currently
connection refusal evidence); a received 503/504 or connection closure remains
ambiguous and returns `resend_permission: :admission_required`. Explicit admission
can authorize a resend after application checks. OpenAI can retry eligible
failures without a hook; this is not a claim of inference idempotency.

The same configuration works with all six adapter APIs, Broker.generate_response,
Broker.generate_object, and `ChatSession.send(session, query, recovery: policy)`.
`recovery: []` keeps the default one-attempt error contract. `nil` keeps legacy
behavior, including its transport defaults.

| Option | Default / semantics |
| --- | --- |
| `max_attempts` | 1; positive integer, includes initial request |
| `base_delay`, `delay_ceiling` | 100 and 30,000 milliseconds, nonnegative integers |
| `retryable_categories` | `[:transport, :http]`; explicit `:client_timeout` selection allowed |
| `retryable_statuses` | `[429, 500, 502, 503, 504]`; explicit HTTP status selection allowed |
| `budget` | Optional monotonic milliseconds measured from first failure |
| `deadline` | Optional absolute monotonic millisecond deadline in the clock's domain |
| `admission` | Optional function of one safe context; allow/reject/pending |
| `cancel_ref` | Optional reference; send `{:cancel, ref}` to the completion caller |
| `observer` | Function of one lifecycle event |
| `clock`, `wall_clock` | Zero-arity monotonic millisecond / UTC DateTime sources |
| `jitter` | Function of exponential ceiling, returns integer in `0..ceiling` |
| `sleeper` | Optional deterministic one-arity delay function returning `:ok` |

Unknown or invalid options fail before dispatch. Protocol/malformed failures and
cancellation cannot be made retryable by category selection. Custom HTTP selection
is explicit policy; it does not waive local admission. Unclassified transports
remain ineligible. Default timeout classification remains unchanged.

The saturating exponential delay doubles only until the configured ceiling.
Elixir integers have arbitrary precision; saturation avoids unbounded exponentiation.
Default jitter is uniform over the inclusive integer interval. Retry-After seconds
and validated HTTP dates provide a minimum against the wall clock observed at
failure. Past dates yield zero; invalid/absent values retain policy delay. A minimum
above the ceiling or a delay reaching the remaining deadline refuses recovery.
Budget and absolute deadline are combined by taking the earlier. Cancellation and
deadline are rechecked after admission/backoff and immediately before dispatch.
An active generation can finish after the recovery deadline. Cancelling active
HTTP stops the local request worker; it does not confirm remote inference stopped.

## Evidence, identities and capabilities

Opt-in Req retries and redirects are disabled. The body, messages, tools, schema,
model, sampling controls and limits remain identical on each resend. No invented
idempotency headers or attempt IDs enter provider payloads. A logical UUID stays
constant per completion; each dispatched attempt has a distinct UUID. Admission
and backoff do not consume wire attempts. Final errors retain ordered safe failure
history bounded by max_attempts, final status and provider ID, Retry-After, observed
and delivered progress, and the original private cause.

`CompletionError.safe_metadata/1`, Inspect, Jason and lifecycle events exclude
request/response text, raw causes, credentials, tool arguments and results.
Provider IDs/codes accept only 1–128 ASCII token characters. Retry-After metadata
is represented explicitly as absent, invalid, delay seconds or a validated date.
`CompletionError.cause/1` deliberately reveals unsafe retained evidence and must
not be logged without application review. Existing opt-in broker trace redaction
is preserved. Applications remain responsible for their own hooks and tool logs.

Events include attempt_started/succeeded/failed, admission_pending/allowed/rejected/required,
backoff_started, retry_started, exhausted and cancelled. Final events carry actual wire counts
and ordered history. A dispatch cancelled or refused after its start notification
has no additional wire attempt in the final outcome. Local UUIDs correlate events;
they provide no provider-side idempotency.

`Recovery.capabilities/1` reports implemented boundary support for all three
providers: local request cancellation supported; remote per-request cancellation,
request-status queries and idempotency unsupported; exact remote termination
unknown. This describes this client's integration, not every server version.
The inspected [Ollama chat API](https://docs.ollama.com/api/chat),
[OpenAI chat API](https://developers.openai.com/api/reference/resources/chat), and
[oMLX project](https://github.com/jundot/omlx) do not provide a termination facility
implemented by these adapters. No unsupported facility is advertised as usable.
Model unload/list/activity observations are not exact-attempt termination evidence.
There is no automatic remote termination checker; an application needing one must
perform its checks before explicitly allowing admission.

| Provider | Local HTTP cancellation | Remote request cancellation | Request status | Idempotency | Exact remote termination |
| --- | --- | --- | --- | --- | --- |
| OpenAI | Supported with cancel_ref | Unsupported in this client | Unsupported in this client | Unsupported in this client | Unknown |
| Ollama | Supported with cancel_ref | Unsupported in this client | Unsupported in this client | Unsupported in this client | Unknown |
| oMLX | Supported with cancel_ref | Unsupported in this client | Unsupported in this client | Unsupported in this client | Unknown |

## Acceptance cases

The tests use public entrypoints and an actual loopback HTTP server through
production Req. They compare complete received requests and exact safe metadata.
Existing Mox tests mock only the HTTP gateway boundary, not Req internals.

| Test name suffix / cases | Scope and assertion |
| --- | --- |
| `ambiguous local 504 waits for explicit admission and preserves complete wire payload` | Proof-first Ollama ordinary request: pending does not resend; explicit allow resends identical bytes, distinct IDs, exact ordered 504 evidence |
| `real Req 503 recovers with identical full payload and correlated lifecycle` | All six paths; admissible recovery, exact Retry-After and request ID, full event sequence and attempt/logical identity correlation |
| `real Req persistent 504 exhausts with ordered exact evidence` | All six; 3 actual requests, distinct provider/attempt IDs, ordered failure details |
| `real Req Retry-After HEADER respects observed wall clock and policy minimum` | All six, HTTP 429: seconds, future date, past date, invalid value; exact received metadata, deterministic jitter and delay |
| `real Req local recovery refuses REASON with KEYS` | Ceiling, budget, initial absolute deadline, no admission, explicit reject; exact retained failure and request payload |
| `real Req cancellation during PHASE is authoritative and sends no retry` | All six at active request, pending admission and backoff |
| `recovery deadline allows active generation to finish` | All six; held real request finishes after injected clock crosses deadline |
| `no resend at exact deadline after PHASE` | All six, admission and backoff clock advancement; original status retained and no second request |
| `real Req permanent failure does not retry under bounded recovery` | All six; 400, 401, 403, 404 and 422 |
| `real Req decoding KIND retains exact evidence without resends` | Existing malformed outer JSON, invalid structured JSON, provider-error envelope and parser exception probes now use max_attempts 3 |
| `real Req recovers after exact tool result without tool replay` | All providers, Broker and ChatSession; exact assistant/tool call IDs and serialized results, one execution, complete resends, retained session history |
| `recovery freezes legacy adaptation of history schema tools and controls` | All six; full wire equality against a legacy request with custom controls, history, schema and tools |
| `real Req monotonic budget begins at first failure and never resets on later failures` | Initial generation time excluded; second failure reaches the original budget and cannot resend |
| `real Req exponential full jitter doubles and saturates at the configured ceiling` | Exact ceilings 10, 20, 25, 25 and deterministic jitter delays |
| `real Req jitter ceilings saturate without exponent overflow` | A 1024-bit base is capped at 17 before jitter |
| `real Req cancellation kills blocked PHASE callback worker` | Both admission and sleeper workers emit DOWN before completion cleanup finishes |
| `real Req pending admission requires explicit DECISION` | All six, allow and reject, exact received evidence and unchanged complete requests |
| `real Req sleeper FAILURE failure never enters safe errors history events or logs` | Secret-bearing return and raised exception become backoff_failed; exactly one request, no secret in errors/history/events/logs |
| `real Req recovery does not replenish broker tool depth` | A recovered second tool request still exhausts depth one; one execution |

The proof was run before fixture/documentation expansion and the full quality
suite. The original implementation rejected with actual exit **2** because it
rejected bounded recovery before dispatch. The corrected source passed with
exit **0**, including pending admission, identical wire bytes and ordered exact
metadata. `.foundry/proof.json` and its existing logs record these commands and
actual outcomes. The source change implements behavior, not a marker toggle.

## Final validation

Every acceptance row above passed. `.foundry/logs/cases.log` retains all individual
case names and results: **316 focused tests, zero failures**. The full suite
passed **22 doctests and 1,154 tests**, with the existing **19 integration
exclusions**. Coverage is **88.57%**, above the unchanged **80%** threshold.
Final compile, test and focused-test stderr are empty. Strict Credo reports zero
issues. The test support module was moved out of a test file to remove a full-suite
load-order failure. Generated refusal tests use a helper to eliminate compiler
warnings about constant comparisons. No warnings or checks were suppressed.

| Command | Actual result | Log in `.foundry/logs/` |
| --- | --- | --- |
| `mix format --check-formatted` | Exit 0 | format.log |
| `mix compile --warnings-as-errors` | Exit 0 | compile.log |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0 | compile-test.log |
| `mix credo --strict` | Exit 0, zero issues | credo.log |
| `mix test --cover` | Exit 0, 88.57% | coverage.log |
| `mix test` | Exit 0, zero failures | test.log |
| Focused recovery tests with `--trace` | Exit 0, 316 tests | cases.log |
| Final admission proof | Exit 0 | corrected.log |
| `mix deps.audit` | Exit 0, no vulnerabilities in checked database | deps-audit.log |
| `mix hex.audit` | Exit 0, no retired/security advisory packages | hex-audit.log |
| `mix sobelow --config` | Exit 0, no findings under existing configuration | sobelow.log |
| `mix docs` | Exit 0, existing unresolved tracer type-reference warnings | docs.log |
| `mix hex.outdated --all` | Exit 1, updates available, informational | hex-outdated.log |
| `mix dialyzer` | Exit 1, unavailable task | dialyzer.log |

Commands ran through `foundry capture` with `/tmp/mojentic-mix`, selecting the
installed pinned Elixir **1.18.5** and OTP **28.5.0.7**, with writable
`HEX_HOME=/tmp/mojentic-recovery-hex`. The toolchain log records the runtime.
Dependencies were restored from the existing lockfile. No dependency, package,
supported-version or CI pin changed, and no precommit alias is configured.

MixAudit's shared advisory database could not refresh because its FETCH_HEAD is
read-only. Read-only comparison confirmed local HEAD and upstream main both equal
`935abf7410a2bbb18e12579dee6e31267c3ed244`; advisory-local.log and
advisory-remote.log retain the evidence. No advisory suppression changed.
Sobelow emits existing lockfile quoted-keyword warnings without findings; this
is not a Phoenix project. Docs generation retains existing undefined/private
`TracerEvent.t/0` references. Dialyxir is absent, so Dialyzer/PLT verification
remains unavailable and is not claimed as passing. Adding a dependency or
changing its CI cache conflicts with the dependency freeze. Sleeper failures are normalized to `:backoff_failed`; arbitrary callback return
values and exceptions never enter safe metadata. These limitations
are recorded, not waived. Changes remain uncommitted for Foundry finalization.
