# Offline verification

Base commit: `38875faede2679690483d7b8ec2f70fdeefafaaa`.
Worktree identity: `/home/svetzal/.foundry/worktrees/mojentic-ex/mojentic-ex-no-network-tests-c1-9b2373`.
The executable snapshot is the base plus the uncommitted inputs identified by the
manifests below. Foundry owns finalization; no commit, ref change, push or release
was performed. Production `lib/`, public API, dependencies, runtime pins,
coverage floor/exclusions and GitHub workflow configuration are unchanged.

## Required gate-file results

Every command in `.hone-gates.json` completed successfully on this snapshot.

| Gate | Exact command | Exit |
| --- | --- | --- |
| format | `scripts/recovery-mix format --check-formatted` | 0 |
| compile | `scripts/recovery-mix compile --warnings-as-errors` | 0 |
| credo | `scripts/recovery-mix credo --strict` | 0 |
| test | `scripts/recovery-mix test --cover` | 0 |
| deps-audit | `scripts/recovery-mix deps.audit` | 0 |
| sobelow | `scripts/recovery-mix sobelow --config` | 0 |
| first-token-contract | `scripts/verify-first-token-contract` | 0 |
| readiness-contract | `scripts/verify-readiness-contract` | 0 |
| packaged-first-token | `scripts/verify-packaged-first-token` | 0 |

Full suite:

```text
Finished in 244.1 seconds (144.9s async, 99.1s sync)
22 doctests, 6091 tests, 0 failures, 19 excluded
    91.22% | Total
```

The pinned runtime remains Elixir 1.18.5 / OTP 28.5.0.7. The existing 80% coverage
threshold and exclusions are unchanged. Server-only gate timeout allowances
were removed. Complete command logs and the validated behavioral proof are
preserved in Foundry's execution evidence, outside committed project files.

## Shared executable identity and both consumers

The version remains `ex-readiness-v1`, with `ex-stream-first-token-v1` and the
existing versioned recovery, reasoning, context and fidelity inputs. The
manifest hashes identify the changed executable implementation, rather than
relying only on a version label or case count.

| Executable manifest | SHA-256 |
| --- | --- |
| `test/contracts/context_window_v1.manifest.sha256` | `4343abd68c3d9a9a74cd1fc750cfcccaa9378cc760aace037204b64276c5ed68` |
| `test/contracts/readiness_v1.manifest.sha256` | `6baf03b987e72eea0bfefbad0d5dbab4ead7e8c65d0aa308c9e0bc4cbface65c` |
| `test/contracts/stream_first_token_v1.manifest.sha256` | `fab2a47c25f2e72fde63abd0ae4292c096b56d94a67b53a718f97429de2878b8` |

Source-provider/public-source-consumer verification:

```text
Finished in 178.3 seconds (104.2s async, 74.0s sync)
5374 tests, 0 failures
```

First-token source verification:

```text
Finished in 39.7 seconds (0.00s async, 39.7s sync)
864 tests, 0 failures
```

Fresh packaged-provider/public-consumer verification:

```text
Finished in 196.5 seconds (116.2s async, 80.3s sync)
5374 tests, 0 failures
```

Tested local Hex payload SHA-256: `d3431514db1345899953fba9a59f92a8913e0e1219ef9d978e3adfa78d6e7747`.

The fresh consumer uses the actual extracted Hex contents and a separate Mix
project. The extracted provider files and copied consumer test/fixture inputs
are independently checked against the same source manifest before execution.
Dependency sources and compiled dependencies are supplied locally; Mojentic is
excluded from the reused build and compiled afresh. `HEX_OFFLINE=1` is set before
packaging; there is no `deps.get` or registry access. A separate code-path check
confirms ReqClient resolves from the fresh consumer's own Mojentic build.
This verifies the distribution/library boundary; no running service boundary or
external port adoption is claimed.

## Behavioral assertions and sensitivity

[The decision map](../test/contracts/DECISIONS.md) and
[current conformance](../CONFORMANCE-3.0.0.md) name the assertions, input values,
expected public outputs/errors and adapter-observed requests for every binding
parts 1–3 decision; parts 4–5 applicability is explicit.

The focused public OMLX probe runs real ReqClient preparation and dispatch with
an in-process Req adapter and injected clock. Capture at 80, preparation at
100, observation at 125 and rejection at 180 produce ordered capture/preparation/
dispatch, first token 25ms, duration 80ms, capture_failed, observed content true,
delivered content false, one exact request and a closed response. Emptying the
actual transport delta rejects the observed-content assertion (exit 2);
restoring `answer` passes (exit 0). No mutation remains. The proof JSON's shape,
actual recorded exit codes and log existence were validated.

EOF cancellation and process-death cleanup are also exercised explicitly:
complete Content-Length bodies end independently of fixture release, and
monitored cleanup uses closure-message handshakes. The idle/absolute timeout
replacement uses a zero timeout and queued data, never a real wait or elapsed
threshold. The identity-verifier negative matrices independently reject
corrupted identities and missing transitions through the same behavioral
observations.

There are no sockets/servers, positive sleeps or wall-clock assertions in the
migrated HTTP/contract suites. Req's documented adapter is the I/O boundary;
Mojentic internals are not mocked. Transport transcripts contain the prepared
method, path, headers and exact body; they do not claim generated protocol
framing or remote termination. Existing unrelated async-agent, dispatcher,
tool-runner and realtime timing cleanup remains outside this correction.

## Additional checks and limits

`MIX_ENV=test scripts/recovery-mix compile --warnings-as-errors` and
`MIX_ENV=test scripts/recovery-mix dialyzer` pass. `scripts/recovery-mix docs`
passes with pre-existing missing-link warnings for the sibling release plan,
README LICENSE link and Igniter usage-rules path.

Security checks use local snapshots without network access. MixAudit reports no
vulnerabilities using advisory database commit `83be990cdd1105386d97f133b041215e97a58a61`; its network
synchronization command is disabled only in the execution environment, without
filtering any advisories. Offline `mix hex.audit` reports no retired or security
advisory packages. Offline `mix hex.outdated --all` exits 1 because cached
registry data lists available updates; upgrade visibility is not a blocker and
dependencies were not changed. No advisory suppressions were added or modified.

The local recovery contract exactly matches the authoritative sibling text at
SHA-256 `141d4ee5fcfbc18c940a7e7fe8d5ba9e381abc41a6d03f300f541e0fd5236f9d`.
MODEL-METADATA remains bound to
`d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c`.
No sibling files were changed. No unresolved behavioral contract gap remains.
