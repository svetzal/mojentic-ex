# OpenAI Model Registry

The OpenAI Model Registry manages model-specific configurations, capabilities, and parameter requirements for OpenAI models. The registry is an immutable struct that classifies models and tracks their capabilities, enabling the broker to make appropriate API calls with correct parameters.

## Model Types

The registry classifies models into four categories:

- `:reasoning` - Models like o1, o3, gpt-5 that use `max_completion_tokens` instead of `max_tokens`
- `:chat` - Standard chat models that use `max_tokens`
- `:embedding` - Text embedding models
- `:moderation` - Content moderation models

## Model Capabilities

Each model has an associated capabilities map with the following fields:

- `model_type` - Atom indicating model category (`:reasoning`, `:chat`, `:embedding`, `:moderation`)
- `supports_tools` - Boolean indicating function/tool calling support
- `supports_streaming` - Boolean indicating streaming response support
- `supports_vision` - Boolean indicating image input support
- `max_context_tokens` - Maximum input context tokens (integer or `nil`)
- `max_output_tokens` - Maximum output tokens (integer or `nil`)
- `supported_temperatures` - Temperature parameter constraints:
  - `nil` - all temperature values allowed
  - `[]` - no temperature parameter accepted
  - `[1.0]` - only specific value(s) allowed
- `supports_chat_api` - Boolean indicating `/v1/chat/completions` endpoint support
- `supports_completions_api` - Boolean indicating `/v1/completions` endpoint support
- `supports_responses_api` - Boolean indicating `/v1/responses` endpoint support

## API Endpoint Support

OpenAI models support three different API endpoints:

- **Chat API** - `/v1/chat/completions` - Most models use this endpoint (default)
- **Completions API** - `/v1/completions` - Legacy models (babbage-002, davinci-002, gpt-3.5-turbo-instruct)
- **Responses API** - `/v1/responses` - Newer models (gpt-5-pro, codex-mini-latest, o1-pro)

Some models support multiple endpoints:
- `gpt-4o-mini` supports both Chat and Completions
- `gpt-5.1` supports both Chat and Responses

Note: The current gateway implementation only calls the Chat API. The endpoint support flags are informational and will be used in future gateway enhancements.

## Usage

```elixir
alias Mojentic.LLM.Gateways.OpenAIModelRegistry

# Create a registry
registry = OpenAIModelRegistry.new()

# Look up model capabilities
caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4o")
caps.model_type          # :chat
caps.supports_tools      # true
caps.supports_streaming  # true
caps.supports_chat_api   # true

# Check endpoint support for a dual-endpoint model
mini_caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-4o-mini")
mini_caps.supports_completions_api  # true
mini_caps.supports_chat_api         # true

# Check a responses-only model
pro_caps = OpenAIModelRegistry.get_model_capabilities(registry, "gpt-5-pro")
pro_caps.supports_chat_api          # false
pro_caps.supports_responses_api     # true

# Get the correct token limit parameter name
OpenAIModelRegistry.get_token_limit_param(registry, "o1")
# => "max_completion_tokens"

OpenAIModelRegistry.get_token_limit_param(registry, "gpt-4o")
# => "max_tokens"

# Check temperature support
OpenAIModelRegistry.supports_temperature?(registry, "gpt-4", 0.7)  # true
OpenAIModelRegistry.supports_temperature?(registry, "o1", 0.7)     # false
OpenAIModelRegistry.supports_temperature?(registry, "o1", 1.0)     # true

# Register a custom model (returns new registry - immutable)
new_registry = OpenAIModelRegistry.register_model(registry, "custom-model", %{
  model_type: :chat,
  supports_tools: true,
  supports_streaming: true,
  supports_vision: false,
  max_context_tokens: 8000,
  max_output_tokens: 4000,
  supported_temperatures: nil,
  supports_chat_api: true,
  supports_completions_api: false,
  supports_responses_api: false
})
```

## Model Categories by Endpoint

### Chat-only Models

Most GPT-4 variants, o1, o3, o4-mini, gpt-5 base models:
- gpt-4, gpt-4-turbo, gpt-4o
- o1, o1-mini, o3, o3-mini, o4-mini
- gpt-5, gpt-5-mini

### Completions-only Models

Legacy models that only support the Completions API:
- babbage-002
- davinci-002
- gpt-3.5-turbo-instruct

### Dual-endpoint Models (Chat + Completions)

- gpt-4o-mini
- gpt-4.1-nano
- gpt-5.1

### Responses-only Models

Newer models using the Responses API:
- gpt-5-pro
- codex-mini-latest
- o1-pro, o3-pro
- o3-deep-research, o4-mini-deep-research

## Pattern Matching

The registry uses pattern matching to infer capabilities for unknown models based on name patterns. For example:

- Models starting with `o1` are classified as reasoning models
- Models containing `vision` are marked with vision support
- Models ending in `instruct` are flagged as completions-only

This allows the registry to handle new model variants without requiring explicit registration.

## Immutability

The registry follows Elixir's immutable data structures. All modification functions (`register_model/3`, `register_pattern/3`) return a new registry instance:

```elixir
registry1 = OpenAIModelRegistry.new()
registry2 = OpenAIModelRegistry.register_model(registry1, "custom-model", capabilities)

# registry1 remains unchanged
# registry2 contains the new model
```
