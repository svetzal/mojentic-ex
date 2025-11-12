# Mojentic Examples

This directory contains example scripts demonstrating various features of the Mojentic Elixir library.

## Prerequisites

Before running these examples, ensure you have:

1. **Elixir installed** (version 1.14 or later)
2. **Ollama running locally** at `http://localhost:11434`
3. **At least one model pulled**, for example:
   ```bash
   ollama pull phi4:14b
   ollama pull qwen2.5:3b
   ```

## Available Examples

### Level 1: Basic LLM Usage ✅

All Level 1 examples are complete and ready to use.

#### `simple_llm.exs`
Basic text generation with a local LLM model.

```bash
mix run examples/simple_llm.exs
```

Demonstrates:
- Creating a broker with Ollama gateway
- Sending a single user message
- Receiving and displaying a response

#### `list_models.exs`
List all available models from the Ollama gateway.

```bash
mix run examples/list_models.exs
```

Demonstrates:
- Querying available models
- Error handling for gateway connection issues

#### `structured_output.exs`
Generate structured JSON output using a schema.

```bash
mix run examples/structured_output.exs
```

Demonstrates:
- Defining a JSON schema
- Getting structured data from the LLM
- Parsing and using the structured response

#### `tool_usage.exs`
Use tools (functions) that the LLM can call.

```bash
mix run examples/tool_usage.exs
```

Demonstrates:
- Defining and registering tools
- LLM making tool calls
- Executing tool functions
- Sending tool results back to the LLM

### Level 2: Advanced LLM Features ⚠️

#### `image_analysis.exs` ✅
Analyze images using vision-capable models.

```bash
mix run examples/image_analysis.exs
```

Demonstrates:
- Multimodal messages with images
- Base64 encoding of image files
- Using vision-capable models (qwen3-vl, gemma3, llava)
- Extracting text from images

**Requirements**: Vision-capable model such as `qwen3-vl:30b`, `gemma3:27b`, or `llava:latest`

## Configuration

### Environment Variables

You can customize behavior using these environment variables:

- `OLLAMA_HOST` - Ollama server URL (default: `http://localhost:11434`)
- `OLLAMA_TIMEOUT` - Request timeout in milliseconds (default: `300000` = 5 minutes)

Example:
```bash
export OLLAMA_HOST=http://localhost:11434
export OLLAMA_TIMEOUT=60000
mix run examples/simple_llm.exs
```

## Troubleshooting

### "Error fetching models" or connection refused

Make sure Ollama is running:
```bash
ollama serve
```

### Model not found

Pull the model first:
```bash
ollama pull phi4:14b
```

### Timeout errors

Increase the timeout for larger models:
```bash
export OLLAMA_TIMEOUT=600000  # 10 minutes
mix run examples/simple_llm.exs
```

## Next Steps

After running these examples, check out:

- [Main README](../README.md) - Library overview and installation
- [API Documentation](../doc/index.html) - Generated with `mix docs`
- [Test Suite](../test/) - More examples in the test code

## Coming Soon

The following examples are planned for future implementation:

### Level 2: Advanced LLM Features (Remaining)
- `streaming.exs` - Streaming responses
- `chat_session.exs` - Interactive chat sessions
- `broker_examples.exs` - Comprehensive broker feature tests

### Level 3: Tool System Extensions
- `file_tool.exs` - File operations
- `task_manager.exs` - Task management

### Level 4: Tracing & Observability
- `tracer_demo.exs` - Event tracing and debugging

See [PARITY.md](../PARITY.md) for the complete feature roadmap.
