All done. Here's a summary of what was updated:

| Package | Old | New | Type |
|---------|-----|-----|------|
| `ex_ast` | 0.11.1 | 0.11.2 | patch (transitive via `igniter`) |
| `finch` | 0.21.0 | 0.22.0 | minor (transitive via `req`) |

All other 36 dependencies were already at their latest versions. Every quality gate passed cleanly:
- ✅ `mix format --check-formatted`
- ✅ `mix compile --warnings-as-errors`
- ✅ `mix credo --strict` — zero issues across 802 modules/functions
- ✅ `mix test --cover` — 88.87% coverage (above the 80% threshold)
- ✅ `mix deps.audit` — no vulnerabilities