# Changelog

All notable changes to the Mojentic Elixir implementation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — completion recovery and readiness verification

- Opt-in completion recovery for OpenAI, Ollama and oMLX, across ordinary,
  structured and streaming APIs, Broker and ChatSession. Recovery replays only
  one immutable provider request; completed tools and the agent loop are not
  replayed. Typed errors expose safe status, progress, attempt identity and bounded
  history, with explicit accessors for private cause/received evidence. Lifecycle
  events omit payloads; exact request/response capture is opt-in.
- Configure `CompletionConfig.new(recovery: [max_attempts: 3])` for bounded
  retries. Recovery is disabled by default; `recovery: []` opts into typed errors
  with one attempt. OpenAI eligible transient failures can retry without a hook;
  Ollama/oMLX ambiguous acceptance requires admission. Backoff respects jitter,
  Retry-After and recovery budgets. Partial semantic streams interrupt rather
  than resend. See the Broker guide for asynchronous admission and cancellation.
- `ex-readiness-v1` runs the same public-API contract cases from source and a
  fresh consumer of the extracted local Hex payload: recovery, native reasoning,
  context discovery, request fidelity and timing. This establishes the declared
  library cases under the October 17 self-validation policy. Dependent adoption
  follows publication; the coordinated release hold remains.

### Fixed — stream dispatch timing

- Start the client clock immediately before the production Req adapter sends,
  after request capture and preparation. Blocked request capture adds no latency;
  rejection, exception or cancellation before dispatch creates no HTTP request or
  dispatch timing. Response observation remains ahead of response capture.
- Verify exact continuation requests and shared retry clocks across OpenAI,
  Ollama and oMLX, including Broker and ChatSession. A fresh consumer verifies
  the locally built Hex payload through the same public-API executable cases.

### Added — client stream timing

- Every production OpenAI, Ollama and oMLX stream reports monotonic
  `time_to_first_token_ms`, `first_token_kind` and `request_duration_ms` in
  terminal metadata, including failures. Empty streams omit the first-token pair.
  Thinking takes precedence over content, then nonempty tool arguments, within
  the first token-bearing frame. Keepalives, names and empty fragments do not count.
- One dispatch clock spans admitted retries; tool continuations start fresh.
  Split-frame observations survive delayed, rejected and cancelled response capture
  without delivering uncaptured output. Provider metrics remain independent.

### Migration — streaming terminal evidence

- Legacy adapter, Broker and ChatSession streams now also yield
  `{:completed, evidence}` for each successful logical completion, including
  a tool turn before its continuation. Handle this tuple alongside content,
  thinking, progress and metrics. Recovery errors retain `CompletionError` and
  expose timing in `error.metadata`; other stream failures without existing
  evidence use `{:stream_error, original_reason, %{metadata: metrics}}`.
- Ollama legacy streaming retains a single HTTP continuation between chunks so
  measurements and cleanup belong to the original request.
- The local `ex-stream-first-token-v1` matrix maps the designated TypeScript v1
  and v2 references through production Req, direct adapters, Broker and ChatSession.
  Readiness follows October 17 library self-validation; dependent adoption follows
  publication. The coordinated release hold remains.

### Fixed — context-window response decoding

- Preserve raw POST response bodies through production Req so Ollama context
  discovery rejects a top-level JSON string containing an object with
  `{:error, :invalid_response}` rather than decoding it twice into a window.
  Valid objects remain accepted. `context-window-v1` now verifies this through
  both direct and Gateway dispatch, and checks shared POST response bytes in
  ordinary, retry-disabled and traced modes. Completion and streaming behavior
  remain covered by the existing suites. Library validation follows the October 17
  self-validation policy.

### Added — context-window discovery

- Optional `Gateway.get_model_context_window/1` callback and compatible
  `Gateway.get_model_context_window(gateway, model)` dispatch; older gateways
  return `{:ok, nil}` without implementing the callback.
- oMLX queries the configured authenticated `/v1/models` endpoint for an exact
  model's positive `max_model_len`. Ollama queries `/api/show` for architecture
  context capacity and optional model `num_ctx`, retaining field provenance.
  OpenAI uses exact registry entries without HTTP or capability fallback guesses.
- Pure `Ollama.effective_context_window/2` clamps advertised capacity by caller
  `num_ctx`, then model `num_ctx`. Discovery does not set request parameters or
  change ChatSession trimming. Unknown advertised capacity remains `nil`.
- `context-window-v1` executable contracts verify local adapters and metadata
  consumers through production Req. Fresh packaged consumption covers these cases alongside timing; the
  coordinated release hold still applies.

### Breaking changes — request fidelity

- `CompletionConfig.temperature`, `num_ctx` and `max_tokens` now default to `nil`.
  OpenAI, Ollama and oMLX omit unset parameters across ordinary, structured and
  both streaming APIs, including Broker/ChatSession, continuations and retries.
  Explicit zero temperature and supported sampling controls are preserved.
- Removed the separate `CompletionConfig.num_predict` field. Migrate
  `num_predict: n` to `max_tokens: n`: Ollama receives `options.num_predict`,
  OpenAI receives `max_tokens` or `max_completion_tokens` for reasoning models,
  and oMLX receives `max_tokens` only when set.
- ChatSession no longer injects temperature 1.0. Per-send sampling/context/output
  settings are forwarded; per-send temperature overrides the optional session
  value. Local history trimming (`max_context`) remains independent.

Migration: restore the former request settings explicitly with
`CompletionConfig.new(temperature: 1.0, num_ctx: 32_768, max_tokens: 16_384)`.
When reading these optional fields, guard numeric operations and comparisons
with `is_number/1` or `is_integer/1`; Erlang term ordering makes `nil > 0` true.
For ChatSession set `temperature: 1.0` in `new/2` and pass `num_ctx: 32_768,
max_tokens: 16_384` to each send. Otherwise Ollama uses model/server settings,
possibly a smaller context and unlimited output; OpenAI may generate more output
and cost more; oMLX uses server defaults. Fixed-temperature OpenAI adaptation and
reasoning-drop warnings remain in place for explicit caller controls.


### Verified

- Extended `request-fidelity-v1` through production Req for Broker legacy
  streaming tool continuations and ChatSession streaming sends on OpenAI,
  Ollama and oMLX. All seven contract rows verify complete initial/continuation
  bodies, native parameter names and omissions, one tool execution, byte-identical
  continuation retries after an admitted 503, final output and session history.
  Existing production forwarding and finalization already conform; source and
  fresh packaged consumers now verify the same cases.

- Established the October 12 admission-without-a-hook guarantee through the real
  Req boundary across OpenAI, Ollama and oMLX ordinary, structured, event and
  legacy streaming APIs, Broker and ChatSession. Eligible OpenAI failures may
  retry; local failures require admission unless transport evidence proves
  nonacceptance. Tests exercise real connection refusal, exact request replay,
  forbidden resends, lifecycle identities and default single-attempt behavior.
  Existing production policy already conformed; no policy change was needed.

### Changed

- Completion recovery capabilities now cite inspected provider documentation,
  exact endpoints and inspection dates through `Recovery.capability_evidence/1`.
  Migration: `Recovery.capabilities/1` retains its five atom keys and atom values;
  oMLX local request cancellation and idempotency change to `:unknown` because
  its documented endpoint inventory leaves those facilities ambiguous. Treat
  unknown as unproven, never as permission to resend. Local cancellation behavior
  and all other recovery policies remain unchanged. Exact-attempt termination
  remains unknown for every maintained adapter.

### Fixed

- Recovery policies now fail with `CompletionError` category `:policy` on every
  gateway, Broker and ChatSession entrypoint, with zero HTTP dispatch. Capture
  failures retain their typed completion error and `:capture_failed` cause.
  Length-limited ordinary and structured responses now fail inside recovery
  before parsing truncated JSON or executing tools. OpenAI and oMLX recovery
  legacy streams retain `{:incomplete_completion, "length"}` instead of losing
  it to `:invalid_stream_event`. Failed session streams cannot finalize as success.
  Migration: match policy category `:policy` instead of `:protocol`; inspect
  length/capture causes through `CompletionError.cause/1`. Recovery-disabled
  successful behavior, including legacy oMLX length responses, is preserved.

- Recovery-enabled oMLX streams now skip data frames whose model is exactly
  `keepalive` before semantic observation, parsing and fallback capture evidence.
  Their bytes remain raw progress; they cannot change provider model, usage,
  completion, reasoning or tools. Real semantic output still prevents replay,
  and keepalive-only truncation still requires the existing admission decision.
  Production Req regressions cover both gateway APIs, Broker and ChatSession.

- Correct RFC 850 Retry-After century rollover by comparing the complete timestamp
  against the recovery wall clock's 50-year cutoff, including month, day and time.
  Dates exactly at the cutoff retain their century; later dates roll back before
  weekday validation. Deterministic production-Req regressions cover December 1976
  and one-second cutoff boundaries across gateways, Broker and ChatSession.
- Completion recovery now accepts RFC 850 and asctime Retry-After dates alongside
  IMF-fixdate and delay seconds. Dates normalize to UTC ISO 8601 in safe metadata;
  their observed wall-clock minimum applies to ordinary, structured and both
  streaming APIs, Broker and ChatSession across OpenAI, Ollama and oMLX. Past,
  invalid and absent values preserve the policy delay; delay ceilings and recovery
  budgets still refuse resends. Admission behavior is unchanged.

- Recovery admission hooks that finish without allow/reject, including abnormal
  completion, now stop with the payload-free `:admission_no_decision` resend
  permission and lifecycle event. The original provider failure, identities and
  history remain unchanged; no retry is authorized. Explicit rejection, pending
  asynchronous decisions, cancellation, deadlines and no-hook policy retain their
  behavior across ordinary, structured and both streaming APIs, Broker and ChatSession.

### Breaking changes and migration

- Native reasoning now has six exact effort controls: `:disabled`, `:enabled`,
  `:low`, `:medium`, `:high`, `:xhigh`. Ollama named levels are sent as strings
  rather than being conflated with `true`. Structured requests use the same
  controls. Select `ReasoningProfile.qwen3_8()` explicitly for its exact supported
  efforts; `:enabled` and `:high` are rejected by that profile before HTTP.
  Omitted effort stays unknown. No profile is inferred from a model name.
- `Message.reasoning_content` stores native assistant reasoning separately.
  Set `CompletionConfig.preserve_reasoning: true` to retain completed ordinary
  and streaming Broker tool-turn reasoning (default off); failed, interrupted
  and cancelled streams cannot create retained history. oMLX requests
  `preserve_thinking` and serializes native history as `reasoning_content`;
  Ollama uses `thinking`. Legacy local streams expose `{:thinking, text}`
  separately from visible text; consumers must handle those tuples.
  OpenAI rejects native history, profiles, retention and the new efforts,
  preserving its existing low/medium/high behavior and history format.
  ChatSession `send/3` and `send_stream/3` forward these configuration options;
  session history continues to store the visible final reply. See the Broker
  guide for manual outer-turn native history.

- Callers matching only `:rejected` / `:admission_rejected` must also handle
  `:admission_no_decision`. Return `:reject` for deliberate refusal and `:pending`
  for an asynchronous decision. Unexpected returns (including `:cancelled` and
  `:deadline`) and callback failures are undecided, not caller rejection. Use the
  existing cancellation message and deadline options for authoritative stops.

### Maintenance

- Correct opaque atomics cancellation-handle and tracer-event types for type
  analysis. Realtime transport retains the error path for an invalid WebSocket
  upgrade with empty headers. These changes add no completion-recovery policy.

### Security

- Prevent FileManager sandbox escapes into sibling directories whose names share
  the base path prefix by checking normalized path components.

## [2.1.0] - 2026-09-30

- Reject malformed streaming delta, tool-call and provider evidence shapes with
  terminal validation errors. OpenAI-compatible streams no longer crash on a
  non-object delta. Ollama EOF errors preserve earlier usage and timing evidence.
- Apply `OMLX_TIMEOUT` to connection setup and idle streaming waits, allowing
  active streams to exceed the interval. Reject whitespace-only embedding model
  names before any request.

- Preserve HTTP and HTTPS image URLs and data URIs in OpenAI and oMLX
  requests. Match their schemes without case sensitivity and keep the original
  reference unchanged. Local file paths retain base64 encoding.

- Split OpenAI embedding input into parts of at most 8191 `cl100k_base` tokens.
  Weight each vector by its part token count before normalizing the result.
  The previous chunking stub sent long text whole and used vector dimensions
  as weights.

- Add `Mojentic.LLM.Gateways.OMLX`, a gateway for oMLX (an LLM server for Apple
  Silicon). Configure it with `OMLX_HOST` (default `http://localhost:8000`; the
  gateway adds `/v1`), `OMLX_API_KEY` (a bearer token, sent only when set) and
  `OMLX_TIMEOUT` (milliseconds, default 600000, for every request including load). It sends every configured
  parameter unchanged for any model name (no OpenAI model registry), always as
  `max_tokens`, and forwards `top_k` and `reasoning_effort`. `reasoning_content`
  becomes `thinking`, and usage is kept exactly as reported. A `Warning` header
  on a structured-output request goes into metadata as
  `"response_format_warning"` and is logged. Both streaming APIs drop oMLX
  keep-alive frames, and `Broker.generate_stream_events/3` supports oMLX. New
  public functions `OMLX.load_model/1` and `OMLX.unload_model/1`.
  `calculate_embeddings/2` requires a model and sends one request.
- The OpenAI legacy stream parser reads deltas that omit the `finish_reason`
  key. OpenAI always sends it, so OpenAI streams are unchanged; OpenAI-compatible
  servers that omit it no longer lose content and tool calls.
- `Mojentic.HTTP.ReqClient.get/3` returns the response body as a binary, as
  the `Mojentic.HTTP` behaviour says. It returned Req's decoded map for JSON
  responses, so `get_available_models/0` raised against a real server in the
  OpenAI, Ollama and oMLX gateways. Mocked tests could not see it.

- The Ollama gateway implements `complete_stream_events/3`, so
  `Broker.generate_stream_events/3` works with Ollama as well as OpenAI.
  Completion requires a final frame with `done: true` and `done_reason: "stop"`;
  any other `done_reason` is `{:incomplete_completion, evidence}`, end of stream
  without a final frame is `:incomplete_stream`, and native tool calls are
  `:unexpected_tool_calls`. One HTTP request; halting enumeration cancels it.

- `generate_stream_events/3` evidence names the reported model `provider_model`,
  matching the trace field (was `model`), in both `{:completed, evidence}` and
  `{:incomplete_completion, evidence}`.
- End of stream without a terminal marker is now
  `{:incomplete_stream, evidence}` (was `:incomplete_stream`). `evidence` holds
  whatever arrived first, in the same shape, or is `nil` when nothing did. The
  stream trace records it.
- `generate_stream_events/3` reports a non-2xx HTTP status as
  `{:provider_error, %{status: status}}` (was `{:http_error, status}`) and any
  other transport failure, including the streaming deadline, as
  `{:request_failed, reason}` (was the bare reason, such as `:timeout`).

- The OpenAI gateway forwards `CompletionConfig.response_format` in non-streaming
  `complete/4` requests, as it already did in streaming requests. The Ollama
  gateway already forwarded `format` in both. Forwarding records the request; it
  does not prove the provider enforced the format.

- `Broker.generate/4` returns `{:error, {:incomplete_completion, reason}}` for any
  finish reason other than `"stop"`, including `"length"`. Truncated content is an
  error, never a result. The broker does not continue truncated responses; callers
  that want to resume do so with `generate_response/4`.

- Preserve reported usage, provider model, finish reason and metadata in ordinary
  and structured broker response traces. Missing provider usage remains unknown.

- `generate_stream_events/3` response traces carry the terminal event's usage,
  provider model and finish reason, for completion and incomplete-completion
  terminals. Other failures record them as unknown.
- `generate_stream_events/3` terminal evidence (`{:completed, evidence}` and
  `{:incomplete_completion, evidence}`) carries a nullable provider `metadata`
  map. Ollama puts the final frame's durations there; OpenAI reports `nil`. The
  stream response trace records it as its `metadata`.
- The Ollama gateway fills `usage` (`prompt_eval_count`, `eval_count`),
  `model`, `finish_reason` (`done_reason`) and duration `metadata` on ordinary and
  structured responses. Because `done_reason` is now reported, `Broker.generate/4`
  returns an incomplete-completion error for Ollama responses that stop for any
  reason other than `"stop"`.
- The OpenAI gateway fills `usage`, `model` and `finish_reason` on structured
  responses.

- Add a single-response broker API for caller-owned context and native tool requests.
- Support explicit unlimited tool rounds while retaining finite defaults.
- The broker accepts configured runner structs and a `tool_context`. Timeout and cancelled outcomes retain call identity and notify completion observers.

### Changed

- Updated `req` 0.6.3→0.7.1 (constraint broadened to `~> 0.7`).
- Updated locked `mint` 1.10.0→1.10.1 (and `hpax`) for EEF-CVE-2026-82672, an
  unvalidated chunk-size line tail in the HTTP/1 client.

## [1.5.0] - 2026-05-21

### Added

- `RealtimeVoiceBroker` and `Mojentic.LLM.Gateways.OpenAIRealtime` — WebSocket-based gateway for OpenAI's Realtime API, enabling low-latency voice and streaming sessions.
- `Mojentic.LLM.ToolRunner` abstraction with a serial default — provides a composable interface for executing tool calls outside of the broker's built-in recursion loop.
- OpenAI model registry now recognizes the GPT-5.4 and GPT-5.5 reasoning model families (`gpt-5.4`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5.5`, `gpt-5.5-pro`, plus dated snapshots). These are registered explicitly with their real 1,050,000 / 400,000-token context windows and 128,000-token output cap. Pattern mappings for `gpt-5.3`, `gpt-5.4`, and `gpt-5.5` were also added so unregistered variants still resolve to the reasoning type.
- Realtime and parallel tools examples and accompanying guides.

### Fixed

- Race condition in `SimpleRecursiveAgent.process_iteration` that could cause incorrect completion detection under concurrent load.
- Realtime session blockers and dead code cleaned up in the OpenAI Realtime gateway.

## [1.4.0] - 2026-05-11

### Added

- `max_tool_iterations` field on `CompletionConfig` (default `10`) — bounds recursive tool-calling in both `generate/4` and `generate_stream/4`; returns `{:error, :max_tool_iterations_exceeded}` when the limit is reached (the streaming path yields it as a stream element).
- Integration test exercising the OpenAI tool-calling round-trip (assistant tool-call → tool result → final response), backed by a shared fixture set used across all four mojentic ports.

### Changed

- `SimpleRecursiveAgent` completion detection requires a strict whole-string match for `DONE`/`FAIL` (case-insensitive, trimmed); responses that merely contain those words as substrings no longer trigger completion.
- `AsyncDispatcher` documents that agents matching an event are dispatched concurrently via `Task`s — intentional and safe under the BEAM's process isolation; `SharedWorkingMemory` carries a corresponding note about why that safety holds.

### Fixed

- `AsyncDispatcher.wait_for_empty_queue` could observe an empty queue while agent tasks were still processing events that would enqueue follow-up events; that window is now closed.
- Asynchronous event-handler crashes in `SimpleRecursiveAgent` were swallowed, leaving `solve/2` to hang; handler errors now surface via a `HandlerErrorEvent`.

## [1.3.0] - 2026-04-11

### Removed

- HTTPoison dependency — HTTP calls now use Req exclusively

### Changed

- Updated igniter to 0.7.7
- Updated castore and synced transitive dependencies
- Updated usage_rules to 1.2.5
- Updated credo and resolved lock file mismatches
- Updated dev dependencies

## [1.2.0] - 2026-02-05

### Added

- Reasoning effort control via `CompletionConfig` `:reasoning_effort` field (`:low`, `:medium`, `:high`)
  - Ollama gateway: maps to `think: true` parameter for extended thinking
  - OpenAI gateway: maps to `reasoning_effort` API parameter for reasoning models (o1, o3, etc.)
- `thinking` field on `GatewayResponse` for model reasoning traces (populated by Ollama when reasoning effort is enabled)

## [1.1.0] - 2026-02-05

### Added

- API endpoint support flags on model capabilities: `supports_chat_api`, `supports_completions_api`, `supports_responses_api`
  - Indicates which OpenAI API endpoints each model supports (Chat, Completions, Responses)
  - Populated for all registered models based on endpoint audit data
- New models: `babbage-002`, `davinci-002`, `gpt-5.1-codex-mini`, `codex-mini-latest`
- Missing reasoning models added to registry: `o1-pro`, `o3-pro`, `o3-deep-research`, `o4-mini-deep-research`, `gpt-5-codex`

### Fixed

- `gpt-3.5-turbo-instruct` models now correctly flagged as completions-only (not chat-capable)

## [1.0.2] - 2026-02-01

### Fixed

- `Broker.generate_stream/4` no longer re-initializes the HTTP connection on every chunk during tool-call recursion. The `Enum.take`/`Stream.drop` pattern was fundamentally incompatible with `Stream.resource`-backed streams, causing each token to trigger a full new API request and tool execution cycle. Replaced with `Enumerable.reduce` suspension-based stepping that properly carries stream continuations forward without re-initialization.

## [1.0.1] - 2026-02-01

### Added

- `ChatSession.send_stream/2` and `ChatSession.finalize_stream/1` for streaming responses with automatic conversation history management
  - Two-phase API for immutable session state: `send_stream` returns a stream and handle, `finalize_stream` commits the response
  - Yields content chunks in real-time as they arrive from the LLM
  - Automatically records user message and assembled assistant response in conversation history
  - Supports tool calling through broker's recursive streaming
  - Respects context window limits

## [1.0.0] - 2025-11-27

### 🎉 First Stable Release

This release marks the first stable version of Mojentic for Elixir, released simultaneously across all four language implementations (Python, Elixir, Rust, and TypeScript) with full feature parity.

### Highlights

- **Complete LLM Integration Layer**: Broker, OpenAI + Ollama gateways, structured output, tool calling, streaming with recursive tool execution, image analysis, tokenizer, embeddings
- **Full Tracer System**: Event recording, correlation tracking, event filtering, broker/tool integration
- **Complete Agent System**: Base agents, async agents, event system, dispatcher, router, aggregators, iterative solver, recursive agent, ReAct pattern, shared working memory
- **Comprehensive Tool Suite**: DateResolver, File tools (8 tools), Task manager, Tell user, Ask user, Web search, Current datetime, Tool wrapper (broker as tool)
- **24 Examples**: Full example suite demonstrating all major features
- **OTP Design**: Idiomatic Elixir with GenServer-based components and supervision tree ready

### Added

#### Layer 1: LLM Integration

- `Mojentic.LLM.Broker` - Main interface for LLM interactions with recursive tool calling
- `Mojentic.LLM.Gateway` behaviour - Abstract interface for LLM providers
- `Mojentic.LLM.Gateways.Ollama` - Full Ollama implementation with streaming
- `Mojentic.LLM.Gateways.OpenAI` - OpenAI gateway implementation
- `Mojentic.LLM.ChatSession` - Conversational session management
- `Mojentic.LLM.TokenizerGateway` - Token counting with Rustler NIF
- `Mojentic.LLM.EmbeddingsGateway` - Vector embeddings support

#### Layer 2: Tracer System

- `Mojentic.Tracer.System` - GenServer-based event recording
- `Mojentic.Tracer.EventStore` - Event persistence and querying
- `Mojentic.Tracer.Events` - LLM call, response, and tool events
- Correlation ID tracking across requests

#### Layer 3: Agent System

- `Mojentic.Agents.BaseLLMAgent` - LLM-enabled agent foundation
- `Mojentic.Agents.AsyncLLMAgent` - Async agent with GenServer
- `Mojentic.Agents.AsyncAggregatorAgent` - Result aggregation
- `Mojentic.Agents.IterativeProblemSolver` - Multi-step reasoning
- `Mojentic.Agents.SimpleRecursiveAgent` - Self-recursive processing
- `Mojentic.AsyncDispatcher` - Event routing GenServer
- `Mojentic.Router` - Event-to-agent routing
- `Mojentic.Context.SharedWorkingMemory` - Agent context sharing
- ReAct pattern implementation

#### Tools

- `Mojentic.LLM.Tools.DateResolver` - Natural language date parsing
- `Mojentic.LLM.Tools.CurrentDatetime` - Current time access
- `Mojentic.LLM.Tools.ToolWrapper` - Agent as tool delegation
- File tools: Read, Write, List, Exists, Delete, Move, Copy, Append
- `Mojentic.LLM.Tools.TaskManager` - Ephemeral task management
- `Mojentic.LLM.Tools.TellUser` / `AskUser` - User interaction
- `Mojentic.LLM.Tools.WebSearch` - Organic web search

#### Infrastructure

- 625 tests with 81.56% coverage
- Zero Credo warnings
- ExDoc documentation
- Mix tasks for common operations
