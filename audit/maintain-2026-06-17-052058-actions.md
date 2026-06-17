All done. Here's a summary of what happened:

**Updates applied** (both patch-level, transitive deps):
- `earmark_parser` 1.4.44 → 1.4.45 (used by `ex_doc`)
- `sourceror` 1.12.0 → 1.12.2 (used by `igniter`, `rewrite`, `ex_ast`)

**Held back (no action needed):**
- `finch` 0.22.0 → 0.23.0 blocked by `req`'s constraint (`~> 0.21.0 or ~> 0.22.0`) — this will resolve naturally when `req` releases a new version that relaxes the constraint

**All quality gates passed:**
- ✅ `mix format --check-formatted`
- ✅ `mix compile --warnings-as-errors`
- ✅ `mix credo --strict` — zero issues
- ✅ `mix test --cover` — 739 tests passed, 85.71% coverage (above 80% threshold)
- ✅ `mix deps.audit` — no vulnerabilities
- ✅ `mix sobelow --config` — clean

Committed and pushed to `origin/main`.