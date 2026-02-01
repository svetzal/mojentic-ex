# Changelog

All notable changes to the Mojentic Elixir implementation will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
