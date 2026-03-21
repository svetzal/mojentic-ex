# Project Charter: Mojentic (Elixir)

## Purpose

Mojentic for Elixir is an LLM integration framework that provides a clean abstraction over multiple LLM providers (OpenAI, Ollama) with tool support, structured output, streaming, and an event-driven agent system. It is the Elixir implementation within a multi-language family (Python, Rust, TypeScript) maintaining full feature parity across all ports.

## Goals

- Provide idiomatic Elixir/OTP access to LLM capabilities through a broker/gateway architecture
- Support tool calling, structured JSON output, streaming, and embeddings across providers
- Deliver a composable agent system (base, async, iterative, recursive, ReAct) built on GenServer and event dispatch
- Maintain full feature parity with the Python, Rust, and TypeScript implementations
- Include a tracer system for observability of LLM calls, tool executions, and agent events
- Ship as a publishable Hex package with comprehensive docs and examples

## Non-Goals

- Being a standalone application; this is a library meant to be embedded in other Elixir projects
- Implementing its own LLM inference; it delegates to external providers (Ollama, OpenAI)
- Providing a web UI or REST API; it exposes programmatic Elixir interfaces only
- Abstracting away OTP; users are expected to understand supervision trees and GenServers

## Target Users

Elixir developers building applications that need LLM integration, structured AI output, or multi-agent coordination, who want an idiomatic OTP-based library rather than wrapping Python or calling REST APIs directly.
