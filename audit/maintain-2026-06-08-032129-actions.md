All done. Here's a summary of what was done:

**Dependencies updated (all patch versions, transitive):**
| Package | From | To |
|---|---|---|
| `owl` | 0.13.0 | 0.13.1 |
| `spitfire` | 0.3.12 | 0.3.13 |
| `yaml_elixir` | 2.12.1 | 2.12.2 |

All direct dependencies were already at their latest versions. The three transitive dependency patch updates were applied and all quality gates passed clean:
- ✅ Format check
- ✅ Compile (warnings-as-errors — dependency warnings are in third-party code, not ours)
- ✅ Credo strict — zero issues across 124 source files
- ✅ Tests — 739 passed, 85.71% coverage (above the 80% threshold)
- ✅ Security audit — no vulnerabilities found