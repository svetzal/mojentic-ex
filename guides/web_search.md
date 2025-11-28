# Web Search

The `Mojentic.LLM.Tools.WebSearchTool` enables agents to access real-time information from the internet.

## Configuration

The web search tool typically requires an API key for a search provider (e.g., Tavily, Serper).

```elixir
config :mojentic, :web_search,
  api_key: System.get_env("TAVILY_API_KEY"),
  provider: :tavily
```

## Usage

```elixir
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Tools.WebSearchTool

# Initialize broker
broker = Broker.new("qwen3:32b", Mojentic.LLM.Gateways.Ollama)

# Register the tool
tools = [WebSearchTool]

# Ask a question requiring up-to-date info
messages = [
  Mojentic.LLM.Message.user("What is the current stock price of Apple?")
]

{:ok, response} = Broker.generate(broker, messages, tools)
```

## Supported Providers

- **Tavily**: Optimized for LLM agents
- **Serper**: Google Search API
- **DuckDuckGo**: Privacy-focused search (no API key required for basic usage)
