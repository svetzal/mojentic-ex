# Changelog

All notable changes to the Mojentic Elixir implementation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
