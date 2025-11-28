# File Tools

Mojentic provides powerful tools for interacting with the file system, allowing agents to read, write, and manage files.

## Available Tools

### FileTool

The `Mojentic.LLM.Tools.FileTool` provides basic file operations:

- `read_file`: Read content of a file
- `write_file`: Write content to a file
- `list_dir`: List directory contents
- `file_exists`: Check if a file exists

### CodingFileTool

The `Mojentic.LLM.Tools.CodingFileTool` extends `FileTool` with features specifically for coding tasks:

- `apply_patch`: Apply a unified diff patch to a file
- `replace_text`: Replace specific text in a file
- `search_files`: Search for patterns in files

## Usage

```elixir
alias Mojentic.LLM.Broker
alias Mojentic.LLM.Tools.FileTool

# Initialize broker
broker = Broker.new("qwen3:32b", Mojentic.LLM.Gateways.Ollama)

# Register tools
tools = [FileTool]

# Ask the agent to perform file operations
messages = [
  Mojentic.LLM.Message.user("Create a file named 'hello.txt' with the content 'Hello, World!'")
]

{:ok, response} = Broker.generate(broker, messages, tools)
```

## Security

By default, file tools are restricted to the current working directory. You can configure allowed paths to restrict access further.
