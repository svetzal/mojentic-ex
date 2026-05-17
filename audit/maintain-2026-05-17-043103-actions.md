All dependencies are up to date. Here's the summary:

**Dependency Update Results:**
- All **direct dependencies** were already at their latest versions
- **One transitive dependency** had a patch update available:
  - `spitfire` 0.3.11 → 0.3.12 (a parser library used by `igniter` and `sourceror`)

**Quality Gates — all green:**
- ✅ `mix format --check-formatted` — passed
- ✅ `mix compile --warnings-as-errors` — clean
- ✅ `mix credo --strict` — 0 issues across 99 source files
- ✅ `mix test --cover` — 638 tests + 18 doctests, 0 failures, **88.73% coverage** (above 80% threshold)

The lock file update has been committed and pushed to `main`.