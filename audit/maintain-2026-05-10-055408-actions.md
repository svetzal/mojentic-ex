All dependency updates completed successfully and pushed to `origin/main`. Here's a summary:

**Updated packages:**
| Package | Before | After | Type |
|---|---|---|---|
| `ex_doc` | 0.40.1 | 0.40.2 | patch |
| `igniter` | 0.7.9 | 0.8.0 | minor |
| `makeup_erlang` | 1.0.3 | 1.1.0 | minor (transitive) |
| `mint` | 1.7.1 | 1.8.0 | minor (transitive) |
| `ex_ast` | — | 0.11.0 | new (transitive, required by igniter 0.8.0) |

**All quality gates passed:**
- ✅ `mix format --check-formatted`
- ✅ `mix compile --warnings-as-errors`
- ✅ `mix credo --strict` — 0 issues
- ✅ `mix test --cover` — 633 tests, 0 failures, 88.63% coverage (above 80% threshold)
- ✅ `mix deps.audit` — no vulnerabilities
- ✅ `mix sobelow --config` — clean