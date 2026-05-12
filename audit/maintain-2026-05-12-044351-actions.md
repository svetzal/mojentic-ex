All done. Here's a summary of what was done:

**Dependency Update Summary**

- **ex_ast**: `0.11.0` → `0.11.1` (patch update, transitive dependency via `igniter`)
- All other 36 dependencies were already at their latest versions

**Quality Gates — all passed ✅**
- `mix format --check-formatted` — clean
- `mix compile --warnings-as-errors` — clean
- `mix credo --strict` — 0 issues across 99 files
- `mix test --cover` — 638 tests + 18 doctests, 0 failures, 88.74% coverage (above 80% threshold)
- `mix deps.audit` — no vulnerabilities

The lock file update was committed and pushed to `origin/main`.