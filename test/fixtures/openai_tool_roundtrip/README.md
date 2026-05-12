# OpenAI Tool-Calling Round-Trip Fixtures

These fixtures back the canonical `get_weather` OpenAI tool-calling round-trip test
shared across the four mojentic ports: **mojentic-ts**, **mojentic-py**, **mojentic-ex**,
and **mojentic-ru**.

## Byte-Identity Requirement

The three `.json` files in this directory **must remain byte-identical across all four
ports**. If you need to change any of them, you must update all four ports at the same
time. Do not run any JSON formatter over these files.

## Scenario

The fixtures model the following two-turn conversation:

1. **User** asks: "What's the weather in Paris?"
2. **First HTTP response** (`response-1-tool-call.json`): The model emits a
   `get_weather(location: "Paris")` tool call (`finish_reason: "tool_calls"`).
3. **Tool execution**: The tool returns `{ "temperature_c": 22, "conditions": "sunny" }`
   (captured in `tool-result.json`).
4. **Second HTTP response** (`response-2-final.json`): The model, now aware of the tool
   result, responds with the final answer:
   `"It's currently 22°C and sunny in Paris."` (`finish_reason: "stop"`).

## Files

| File | Description |
|------|-------------|
| `response-1-tool-call.json` | First model response requesting the `get_weather` tool |
| `response-2-final.json` | Second model response with the final answer |
| `tool-result.json` | The weather tool's return value |
