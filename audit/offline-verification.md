# Offline verification

## Tested revision and executable identities

The preserved c1 task ref and this worktree's HEAD both resolve to
`0ea04962659276f0249d68420a97965c1a716297`. This correction remains uncommitted for Foundry finalization.
Production `lib` tree `b2ee200c5ae7c45fa5cf2a2affb6f445a1b6cdb8`, `mix.exs`, `mix.lock`, runtime pins,
public APIs and the 80% coverage floor are unchanged.

The tested source execution tree SHA-256 is `404cc95200e712f76632c8f0a0ae13f0b99686dc5b31b83ff7f32c578e745fb6`.
It hashes the sorted `SHA-256  relative-path\n` records for every file under
`lib/`, `test/`, `scripts/`, `.github/workflows/`, plus `mix.exs`, `mix.lock`,
`.formatter.exs` and `.hone-gates.json`. This identifies the uncommitted inputs
in addition to the base revision; audit prose is outside that executable tree.

The shared executable contract is **ex-readiness-v1**. Source public-API
consumers/provider verification and the fresh Hex payload consumer/provider
verification execute the same selected files and verify the same aggregate
manifest. The per-feature versioned contracts and TypeScript provenance remain
listed in [3.0.0 conformance](../CONFORMANCE-3.0.0.md).

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `80141cf30a543b798d5818c29c1e8af9bd4d027345fbe312f064f23a8a5b8faf` |
| `test/contracts/readiness_v1.manifest.sha256` | `825f0813271441a1dc4b9cbc7aa13720ac828c5787e2fda74f6f6c6331b915ea` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `8bf164765756a2f945b83974d20dea2f4a5e6711f2449c3eddd8836209a5500a` |

Tested local Hex artifact SHA-256: `40721277faa879bbfd9079563e524bee0760c147f408f4d688dd7e683a71687c`.
The extracted provider files and copied consumer inputs are checked against the
same aggregate manifest before execution. The fresh consumer compiles Mojentic
from the actual extracted payload; its final code-path assertion verifies that
ReqClient resolves from that consumer's own build. Locally available dependency
sources and compiled dependencies are reused, excluding Mojentic. HEX_OFFLINE=1
prevents registry access; packaging never publishes or invokes deps.get.

## Final gate observations

All nine configured gates below exited zero on the corrected tree. The runtime
was the existing pinned Elixir 1.18.5 / OTP 28.5.0.7; the gate environment used
MIX_ENV=test and HEX_OFFLINE=1. SHA-256 values identify the complete observed
stdout captures archived with the execution evidence, rather than disposable
checkout paths.

| Command | Exit | Observed stdout SHA-256 |
| --- | --- | --- |
| `scripts/recovery-mix format --check-formatted` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix compile --warnings-as-errors` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/recovery-mix credo --strict` | 0 | `ba4fce160edb1cde9dcd38234743eba2e8155b04e66029003e3ecc7f7ecea33c` |
| `scripts/recovery-mix test --cover` | 0 | `2cf33b16348b3bd893077c2d279021f5b08e02705ef35c46823dea202ab6e625` |
| `scripts/recovery-mix deps.audit` | 0 | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` |
| `scripts/recovery-mix sobelow --config` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `scripts/verify-first-token-contract` | 0 | `4c2768f5c9284bdf06c60e5e610897c811c0463cc027879aa3dfaa845d6a69b2` |
| `scripts/verify-readiness-contract` | 0 | `d584f0f98246a4c6cbbf2c0344a83761362e051ba2d3700fdbef887d8ab4fe9f` |
| `scripts/verify-packaged-first-token` | 0 | `6dfd1117cdf7af99f6031a13c629d9b67965dfa74cd771c36dc823b1a9edd378` |

Full suite with coverage:

```text
Finished in 227.4 seconds (142.9s async, 84.4s sync)
22 doctests, 6084 tests, 0 failures
    91.43% | Total
```

First-token source verification:

```text
Finished in 38.9 seconds (0.00s async, 38.9s sync)
864 tests, 0 failures
```

Readiness source-provider/public-source-consumer verification:

```text
Finished in 170.0 seconds (96.5s async, 73.5s sync)
5374 tests, 0 failures
```

Fresh packaged-provider/public-consumer verification:

```text
Finished in 198.3 seconds (124.0s async, 74.2s sync)
5374 tests, 0 failures
```

## Public behavior and rejecting evidence

`recovery_wire_test.exs`: `<gateway> <operation> cancellation inside retry worker guard retains only dispatched failure` covers OpenAI, Ollama and oMLX ordinary
and structured APIs. The old clock-call counter produced a DOWN with noproc;
the original probe exited 2. The corrected six-case probe exited 0: retry_started
selects the non-caller worker, the worker acknowledges the installed monitor and
stays blocked before cancellation reaches the public request owner. DOWN must
be killed. The exact prepared request is the only dispatch; no retry request is
observed. Returned HTTP 503, request ID wire-request-73, Retry-After 11 seconds,
private response-secret cause, logical/attempt identities and one history entry
survive. The ordered lifecycle ends in cancelled. The behavioral proof JSON's
shape, exit-code types, actual observed exits and log existence were validated.

The first full coverage run exposed a preserved disconnect race in
`first_token_wire_test.exs`: `<provider> <route> recovery <policy> retains first-token timing on disconnect without replay`. The HTTP worker could observe
EOF before the session consumer advanced the injected clock: observed duration
25ms versus expected 80ms. The fixture now releases data, waits for public
content delivery acknowledgement and then injects disconnect. All 30 focused
combinations pass; the final source and packaged runs above verify the same
corrected case with exact 25ms first-token / 80ms duration, terminal error, one
request and no replay. Intermediate failed runs and stale-manifest rejections
are superseded by the final observations above.

`offline_transport_test.exs`: **prepared dispatch precedes observation and
rejected capture retains timing without delivery** still verifies actual public
capture_failed, observed content true, delivered content false, first-token
25ms / duration 80ms, exact POST path/body and correlated response cleanup.
The [decision map](../test/contracts/DECISIONS.md),
[3.0.0 conformance](../CONFORMANCE-3.0.0.md) and
[recovery conformance](../RECOVERY-CONFORMANCE.md) map binding parts 1–3 to
named behavioral assertions, including errors, optional fields, old/new paths,
request fidelity, reasoning, context discovery and parts 4–5 applicability.
Every cited test file exists on this tree.

## Complete offline test surface

The transport migration is preserved: production Req preparation, dispatch,
response observation and cleanup run through an in-process Req adapter. Native
transport failures are injected. Transcripts contain exact prepared method,
path, headers and body; they do not claim generated HTTP framing or remote
termination. Monitors and adapter cancellation callbacks establish local cleanup.

Aggregator waiting uses observation of the public wait call plus a GenServer
barrier. Dispatcher tests hold actual routed workers, assert an exact queue size
of five, exercise the public zero-timeout error and verify draining after release.
Tool-runner tests require overlapping blocked calls and release one slot at a
time; completion callbacks prove reverse completion while returned outcomes keep
input order. Realtime tests await public lifecycle events, monitor normal close,
and interrupt a blocked tool before allowing completion to prove dropped output.
No sleep or stopwatch substitutes for those behavioral assertions.

All test and verification-script files were reviewed and the required source
contract command runs `scripts/verify-offline-test-surface`. Its scan rejects
explicit real clocks/sleeps, wall-clock duration thresholds, socket/server APIs,
model downloads and direct service/registry commands. The scan itself rejected
the remaining OpenAI duration comparison before correction. That timeout case
now injects a native timeout after partial content and uses an injected clock.
Tokenizer operation tests load the committed byte-tokenizer fixture and assert
UTF-8 round trips, empty inputs and counts without Hugging Face requests; the
thin hosted-model-loading wrapper is not exercised against a registry. The
obsolete live-test exclusion and instructions were removed. All ten CI jobs now
have timeout-minutes=30; runtime/dependency versions and coverage policy remain
unchanged.

## Security, documentation and contract copies

MixAudit scans the full existing advisory snapshot at commit
83be990cdd1105386d97f133b041215e97a58a61 and reports no vulnerabilities.
Its git synchronization commands were refused by an execution-environment
wrapper, so the audit reads the existing snapshot without network access or
writes to another checkout. No advisory is filtered or suppressed. Offline
hex.audit reports no retired or security-advisory packages. Offline
hex.outdated --all exits 1 for available updates; upgrade visibility is
informational and dependencies were not changed. Sobelow passes with its
existing configuration unchanged.

The local TRANSIENT-RECOVERY copy matches the authoritative root at
141d4ee5fcfbc18c940a7e7fe8d5ba9e381abc41a6d03f300f541e0fd5236f9d;
the local frozen MODEL-METADATA contract matches
d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c.
Authoritative sibling files were read only. This is library self-validation;
no running service boundary changed and no external port adoption or live model
efficacy is claimed. Dependents verify upon adopting a published version.

Additional final-tree `MIX_ENV=test scripts/recovery-mix dialyzer` verification
exited zero with zero errors. `scripts/recovery-mix docs` exited zero; existing
missing-link warnings remain for README's LICENSE link, the parent release-plan
link and the Igniter usage-rules path. These are reported rather than hidden.
