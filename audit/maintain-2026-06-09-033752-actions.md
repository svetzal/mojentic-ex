All done. Here's the summary:

**Update applied: `req` 0.5.18 → 0.6.1**

This was the only outdated dependency. The 0.6.x release contained two security advisories:

- **GHSA-px9f-whj3-246m** — multipart header injection fix (not used in this project)
- **GHSA-655f-mp8p-96gv** — decompression bomb protection: auto-decoding of zip/tar/gz/csv bodies dropped; only JSON is decoded by default now

The `compressed` option also changed default from `true` → `false`, but since the project only talks to Ollama/OpenAI JSON APIs, there is no functional impact.

**Quality gates all passed:**
- ✅ Format — clean
- ✅ Compile — no warnings in project code
- ✅ Credo strict — no issues
- ✅ Tests — 739 passed (721 tests + 18 doctests), 85.82% coverage (above 80% threshold)
- ✅ Security audit — no vulnerabilities