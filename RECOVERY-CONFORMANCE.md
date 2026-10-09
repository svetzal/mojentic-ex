# Completion recovery conformance: Elixir bounded non-streaming recovery

This increment implements the Policy semantics and Admission sections of
TRANSIENT-RECOVERY-2026-10.md for ordinary and structured completion only.
Streaming recovery and exact wire trace hooks remain work for a later increment.
No live models, releases, sibling ports, harness edits, agent restarts, model
unloads, benchmarks, or tool replay were used.

## Synchronization correction

This correction started with a clean tree at
`f4f50feea2873eb71564e7562860a4339aea4d38`, exactly the preserved
`foundry-task/mojentic-ex-mojentic-ex-transient-recovery-v1-c4-2cd3e7` increment.
Before editing, `git fetch origin` exited **0**. Fetched `origin/main` was
`bff29cf28c9899ea5c1cafc6041bae5157d7c9cc`; `git rev-list --left-right --count
HEAD...origin/main` returned **1 0**. No upstream arrivals or conflicts needed
reconciliation. The final Foundry requirements expressly prohibit rebase and ref
modification, overriding the plan's pull/rebase request. No pull/rebase was
attempted in this run, and no commit, push, merge, tag or release was performed.
Foundry owns finalization; the coordinator's AGENTS.md was preserved unchanged.
The earlier run reported fetch exit 0 and pull exit 1 (read-only FETCH_HEAD);
that historical failed pull is not this run's synchronization outcome.

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

## Cancellation dispatch accounting correction

The licensed change is limited to Public error and progress model, Policy
semantics, Admission and Observability in TRANSIENT-RECOVERY-2026-10.md, and
RECOVERY-REQUEST-2026-10.txt sections 2–5. `Recovery.request/3` now distinguishes
cancellation while the HTTP worker is still in its pre-dispatch guard from
cancellation after dispatch authorization. The worker reports readiness; the
caller checks cancellation, emits `attempt_started`, and authorizes the Req
boundary. A pre-dispatch stop returns `{:not_sent, :cancelled}` so the recovery
loop retains its previous state, count and history. The same monitored cleanup
is used for request, admission and backoff workers. No deadline or generation
timeout was added.

All cases below call production `complete/4` or `complete_object/4` with
`Mojentic.HTTP.ReqClient`, for OpenAI, Ollama and OMLX. There are 24 cases:

| Named public-entrypoint case (provider and operation prefix) | Exact assertions |
| --- | --- |
| `cancellation inside initial worker guard has no wire lifecycle` | Zero server requests; wire_attempt 0; empty history; exactly `[cancelled]`; event metadata equals the complete safe final error, including exact logical/attempt IDs. |
| `cancellation inside retry worker guard retains only dispatched failure` | Exactly the first 503 request, original HTTP category/status/provider request ID/Retry-After/private response cause, one failure with the original logical and attempt IDs, wire_attempt 1; exactly `[attempt_started, attempt_failed, admission_pending, admission_allowed, backoff_started, retry_started, cancelled]`; every event keeps that first identity/count, retry next_attempt 2, failure history and final safe metadata match exactly. |
| `cancellation after initial server dispatch retains actual attempts` | One complete server-observed payload; cancellation history entry equals the started attempt identity, wire_attempt 1; exactly `[attempt_started, attempt_failed, cancelled]`; failure history and final metadata match exactly. |
| `cancellation after retry server dispatch retains actual attempts` | Exactly two identical complete server-observed payloads; history contains the first HTTP failure and dispatched cancellation, distinct exact attempt IDs under one logical ID, counts 1 and 2; exactly `[attempt_started, attempt_failed, admission_pending, admission_allowed, backoff_started, retry_started, attempt_started, attempt_failed, cancelled]`; first six events use the first failure ID/count, last three use the second ID/count, exact history and final safe metadata. |

Pre-dispatch probes use the existing policy clock to synchronize **inside the
HTTP worker's final guard**, distinguish its PID from the completion caller,
and block on a receive. Retry synchronization selects the second HTTP worker
using a supervised Agent. After the guard message, cancellation is sent to the
public completion caller. A monitor proves the blocked worker is killed before
completion returns. Post-dispatch probes wait for a full request independently
observed by the loopback TCP server, which holds the response. Each completion
returns within the bounded Task await and no later request is observed. No
sleep, masked IDs, alternative accepted outcome or substituted HTTP gateway is
used. Existing recovery cases continue to characterize frozen parsing, successful
results, immutable payloads, structured errors, tool depth and session history.

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
and ordered history. A cancellation before dispatch emits no attempt start or
failure; cancellation after dispatch retains that actual attempt. Local UUIDs correlate events;
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

The correction proof ran before expanding the fixture matrix, documentation or
full quality suite. After restoring dependencies from the unchanged lockfile,
the original preserved source rejected the real Req retry-guard probe with
actual exit **2**: cancellation replaced the first HTTP failure, with
resend_permission `:not_granted` instead of `:cancelled`. The corrected source
passed the same probe with actual exit **0**, retaining exactly the original
failure identity/history and seven-event sequence. `.foundry/proof.json` records
the behavioral source change, actual commands/codes, and existing
`.foundry/logs/rejecting.log` and `corrected.log`. The first dependency-missing
invocation was not treated as a behavioral rejection.
`proof-validation.log` records successful validation of the JSON shape, field
types, observed exit codes and both existing behavioral logs.

## Final validation

The full suite passes **22 doctests and 1,178 tests**, zero failures, with the
existing **19 integration exclusions**. Coverage is **88.65%**, above the
unchanged **80%** threshold. Focused recovery characterization passes **340
cases**, including all 24 added dispatch cancellation cases. Named results are
retained in `.foundry/logs/cases.log`. The pre-existing request/admission/backoff
cancellation tests now assert the exact phase-specific category and cause rather
than accepting alternative outcomes. Strict Credo initially rejected the new
retry assertion helper's complexity; extracting shared exact event-ID assertions
resolved it without suppression. No threshold, exclusion or advisory suppression
was added or changed.

| Command | Actual result | Log in `.foundry/logs/` |
| --- | --- | --- |
| `mix format --check-formatted` | Exit 0 | format.log |
| `mix compile --warnings-as-errors` | Exit 0 | compile.log |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0 | compile-test.log |
| `mix credo --strict` | Exit 0, zero issues | credo.log |
| `mix test --cover` | Exit 0, 88.65% | coverage.log |
| `mix test` | Exit 0, zero failures | test.log |
| `mix test test/mojentic/llm/recovery_test.exs test/mojentic/llm/recovery_wire_test.exs --trace` | Exit 0, 340 cases | cases.log |
| Dispatch matrix with `--only dispatch_proof --only dispatch_accounting --trace` | Exit 0, 24 selected cases | dispatch-cases.log |
| Initial retry-guard behavioral proof, preserved source | Exit 2, expected rejection | rejecting.log |
| Same behavioral proof, corrected source | Exit 0 | corrected.log |
| `mix deps.audit` | Exit 0, no vulnerabilities in checked database | deps-audit.log |
| `mix hex.audit` | Exit 0, no retired/security advisory packages | hex-audit.log |
| `mix sobelow --config` | Exit 0, no findings under existing configuration | sobelow.log |
| `mix docs` | Exit 0, existing unresolved tracer type-reference warnings | docs.log |
| `mix hex.outdated --all` | Exit 1, updates available, informational | hex-outdated.log |
| `mix dialyzer` | Exit 1, task unavailable | dialyzer.log |

Commands ran through `foundry capture` and `/tmp/mojentic-mix`, selecting the
installed CI-pinned Elixir **1.18.5** and OTP **28.5.0.7**, with writable
`HEX_HOME=/tmp/mojentic-recovery-hex`. `toolchain.log` records the runtime.
Dependencies were restored from the existing lockfile. No dependency, package,
runtime or CI pin changed; no precommit alias is configured. Both compile logs
are empty after successful final checks.

MixAudit could not refresh its shared advisory database because FETCH_HEAD is
read-only. `advisory-local.log` and `advisory-remote.log` independently confirm
local HEAD and upstream main both equal
`935abf7410a2bbb18e12579dee6e31267c3ed244`. No advisory was ignored. Sobelow
retains its existing configuration and emits existing lockfile quoted-keyword
warnings; this is not a Phoenix project. Docs retain existing undefined/private
`TracerEvent.t/0` references outside the licensed correction. Dialyxir is absent,
so Dialyzer and its PLT/cache prerequisite are unavailable and are not claimed as
passing; adding dependencies or changing CI is outside this increment's scope.
The recovery guide was reviewed and remains aligned with the public cancellation
and admission API.

A final read-only `git ls-remote origin refs/heads/main` confirms main still at
`bff29cf28c9899ea5c1cafc6041bae5157d7c9cc` (`sync-remote.log`), with local HEAD,
fetched main and preserved c4 identity recorded in `sync-local.log`. No arrivals
needed reconciliation. Changes remain in the working tree for Foundry review
and finalization.
