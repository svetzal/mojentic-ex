# oMLX fixtures

Raw responses from a live oMLX server. They back
`test/mojentic/llm/gateways/omlx_test.exs`.

## Provenance

Copied unchanged from `fixtures/omlx/` in the `mojentic-unify` monorepo
(commit `63409fa`), which holds the cross-port oMLX gateway contract
`OMLX-2026-09.md`. mojentic-ex CI cannot see the monorepo, so the files live
here too.

They were captured on 2026-09-29 from oMLX 0.7.0rc1 (Homebrew, macOS, Apple
Silicon) serving `Qwen3.8-27B-MLX-8bit`. Response headers are not included.

Keep the files byte-identical to the monorepo copies. Do not run a JSON
formatter over them. Some files start with a space; that is what the server
sent. To change a fixture, change it in the monorepo and copy it to every
port.

## Files

| File | Request |
| ---- | ------- |
| `chat_thinking.json` | Plain chat, model default (thinking on) |
| `chat_thinking_disabled.json` | Same, with `enable_thinking: false` |
| `chat_tool_call.json` | One tool offered; the model calls it |
| `chat_after_tool_result.json` | The tool result sent back as a `tool` message |
| `chat_json_schema.json` | `response_format` `json_schema`, grammar enforced |
| `chat_length.json` | `max_tokens: 5`; truncated during thinking |
| `stream_thinking.sse` | Streamed plain chat, `include_usage` |
| `stream_tool_call.sse` | Streamed tool call |
| `stream_length.sse` | Streamed, `max_tokens: 5` |
| `models.json` | `GET /v1/models` |
| `model_load.json`, `model_unload.json` | Load and unload |
| `error_model_not_loaded.json` | Unload of a model that is not loaded (400) |
| `error_model_not_found.json` | Chat with an unknown model (404) |
| `error_not_embedding_model.json` | Embeddings with a chat model (400) |

Every stream starts with a keep-alive frame whose `model` is `keepalive`. The
gateway drops it before parsing.
