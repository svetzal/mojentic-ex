Dependency maintenance complete. Here's a summary of what was done:

**Update applied:**
- `telemetry` `1.4.1` → `1.4.2` (patch update, transitive dependency via `finch`)

**All other 37 dependencies were already at their latest versions.**

**Quality gates — all passed:**
| Gate | Result |
|------|--------|
| `mix format --check-formatted` | ✅ |
| `mix compile --warnings-as-errors` | ✅ |
| `mix credo --strict` | ✅ 784 mods/funs, no issues |
| `mix test --cover` | ✅ 651 tests (18 doctests + 633 tests), 0 failures, 88.63% coverage |
| `mix deps.audit` | ✅ No vulnerabilities |

Committed and pushed to `origin/main`.