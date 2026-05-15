All dependencies are now up to date. Here's a summary of what was done:

**Updates applied:**
| Dependency | From | To | Type | Role |
|---|---|---|---|---|
| `castore` | 1.0.18 | 1.0.19 | patch | Indirect (used by `tokenizers` and `mint`) |
| `ex_ast` | 0.11.2 | 0.12.0 | minor | Indirect (used by `igniter`) |

Both are transitive dependencies — no changes were needed to `mix.exs`.

**Quality gates all passed:**
- ✅ `mix format --check-formatted`
- ✅ `mix compile --warnings-as-errors`
- ✅ `mix credo --strict` — 0 issues
- ✅ `mix test --cover` — 638 tests + 18 doctests, 0 failures, 88.74% coverage (above 80% threshold)
- ✅ `mix deps.audit` — no vulnerabilities