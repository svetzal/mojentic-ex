# Building and Using Tools

Tools allow LLMs to perform actions, retrieve information, and interact with external systems. Mojentic makes it easy to create custom tools that LLMs can call automatically.

## What are Tools?

Tools extend LLM capabilities beyond text generation:

- **Information Retrieval**: Fetch current data (weather, dates, APIs)
- **Computations**: Perform calculations, process data
- **System Interactions**: Read files, run commands
- **External APIs**: Call web services, databases

## Tool Lifecycle

```
User Query → LLM → Tool Call Request → Tool Execution → Result → LLM → Final Response
```

The broker handles this loop automatically.

## Creating a Tool

Tools implement the `Mojentic.LLM.Tools.Tool` behaviour:

```elixir
defmodule MyApp.Tools.Calculator do
  @behaviour Mojentic.LLM.Tools.Tool

  @impl true
  def run(arguments) do
    # Extract arguments
    operation = Map.get(arguments, "operation")
    a = Map.get(arguments, "a")
    b = Map.get(arguments, "b")

    # Perform calculation
    result = case operation do
      "add" -> a + b
      "subtract" -> a - b
      "multiply" -> a * b
      "divide" when b != 0 -> a / b
      "divide" -> {:error, {:tool_error, "Division by zero"}}
      _ -> {:error, {:tool_error, "Unknown operation"}}
    end

    # Return result
    case result do
      {:error, _} = error -> error
      value -> {:ok, %{result: value}}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "calculator",
        description: "Perform basic arithmetic operations",
        parameters: %{
          type: "object",
          properties: %{
            operation: %{
              type: "string",
              description: "The operation to perform",
              enum: ["add", "subtract", "multiply", "divide"]
            },
            a: %{
              type: "number",
              description: "First operand"
            },
            b: %{
              type: "number",
              description: "Second operand"
            }
          },
          required: ["operation", "a", "b"]
        }
      }
    }
  end

  def matches?("calculator"), do: true
  def matches?(_), do: false
end
```

## Required Functions

### 1. `run/1` - Execute the Tool

```elixir
@spec run(map()) :: {:ok, any()} | {:error, term()}
```

- Receives arguments as a map
- Returns `{:ok, result}` or `{:error, reason}`
- Result will be sent back to the LLM

**Best Practices:**

```elixir
def run(arguments) do
  # Validate inputs
  with {:ok, validated} <- validate_args(arguments),
       # Perform action
       {:ok, result} <- execute_action(validated) do
    {:ok, result}
  else
    {:error, reason} ->
      # Use standardized error format
      {:error, {:tool_error, reason}}
  end
end
```

### 2. `descriptor/0` - Define the Tool

```elixir
@spec descriptor() :: map()
```

Returns a JSON schema describing the tool to the LLM:

```elixir
%{
  type: "function",
  function: %{
    name: "tool_name",
    description: "What the tool does",
    parameters: %{
      type: "object",
      properties: %{
        # Parameter definitions
      },
      required: [...]  # Required parameters
    }
  }
}
```

**Descriptor Tips:**

- **Clear names**: Use descriptive, action-oriented names
- **Detailed descriptions**: Help the LLM understand when to use the tool
- **Specify types**: Use JSON Schema types (string, number, boolean, etc.)
- **Add constraints**: Use enum, minimum, maximum, pattern, etc.
- **Mark required fields**: Specify which parameters are mandatory

### 3. `matches?/1` - Match Tool Names

```elixir
@spec matches?(String.t()) :: boolean()
```

Check if a tool call name matches this tool:

```elixir
def matches?("my_tool"), do: true
def matches?("my_tool_alias"), do: true
def matches?(_), do: false
```

## Using Tools

Pass tools to the broker:

```elixir
alias MyApp.Tools.Calculator

messages = [
  Message.user("What is 42 times 17?")
]

tools = [Calculator]

{:ok, response} = Broker.generate(broker, messages, tools)
# LLM will call calculator tool and respond with "714"
```

## Built-in Tools

### DateResolver

Resolves relative dates to absolute ISO 8601 dates:

```elixir
alias Mojentic.LLM.Tools.DateResolver

messages = [Message.user("What's the date next Friday?")]

{:ok, response} = Broker.generate(broker, messages, [DateResolver])
# "Next Friday is November 15, 2025"
```

Supports:
- "today", "tomorrow", "yesterday"
- "next Monday", "this Friday"
- "in 3 days", "in 1 week"

### CurrentDateTime

Returns the current date and time:

```elixir
alias Mojentic.LLM.Tools.CurrentDateTime

messages = [Message.user("What time is it?")]

{:ok, response} = Broker.generate(broker, messages, [CurrentDateTime])
```

## Example: Weather Tool

```elixir
defmodule MyApp.Tools.Weather do
  @behaviour Mojentic.LLM.Tools.Tool

  require Logger

  @impl true
  def run(%{"location" => location}) do
    Logger.info("Fetching weather for: #{location}")

    case fetch_weather(location) do
      {:ok, weather} ->
        {:ok, %{
          location: location,
          temperature: weather.temp,
          condition: weather.condition,
          humidity: weather.humidity
        }}

      {:error, reason} ->
        {:error, {:tool_error, "Weather unavailable: #{reason}"}}
    end
  end

  def run(_), do: {:error, {:tool_error, "Missing location parameter"}}

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get current weather conditions for a location",
        parameters: %{
          type: "object",
          properties: %{
            location: %{
              type: "string",
              description: "City name or location to check weather for"
            }
          },
          required: ["location"]
        }
      }
    }
  end

  def matches?("get_weather"), do: true
  def matches?(_), do: false

  # Private helper
  defp fetch_weather(location) do
    # Call weather API
    # ...
  end
end
```

## Example: Database Query Tool

```elixir
defmodule MyApp.Tools.QueryUsers do
  @behaviour Mojentic.LLM.Tools.Tool

  alias MyApp.Repo
  alias MyApp.User

  @impl true
  def run(%{"name" => name}) do
    users =
      User
      |> where([u], ilike(u.name, ^"%#{name}%"))
      |> Repo.all()

    {:ok, %{
      count: length(users),
      users: Enum.map(users, &user_to_map/1)
    }}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "search_users",
        description: "Search for users by name",
        parameters: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "Name or partial name to search for"
            }
          },
          required: ["name"]
        }
      }
    }
  end

  def matches?("search_users"), do: true
  def matches?(_), do: false

  defp user_to_map(user) do
    %{
      id: user.id,
      name: user.name,
      email: user.email
    }
  end
end
```

## Example: File Operations Tool

```elixir
defmodule MyApp.Tools.FileReader do
  @behaviour Mojentic.LLM.Tools.Tool

  @impl true
  def run(%{"path" => path}) do
    # Validate path for security
    case validate_path(path) do
      :ok ->
        case File.read(path) do
          {:ok, content} ->
            {:ok, %{
              path: path,
              content: content,
              size: byte_size(content)
            }}

          {:error, reason} ->
            {:error, {:tool_error, "Cannot read file: #{reason}"}}
        end

      {:error, reason} ->
        {:error, {:tool_error, reason}}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "read_file",
        description: "Read contents of a text file",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the file to read"
            }
          },
          required: ["path"]
        }
      }
    }
  end

  def matches?("read_file"), do: true
  def matches?(_), do: false

  defp validate_path(path) do
    # Security: Only allow certain directories
    allowed_dirs = ["/tmp", "/data", "/uploads"]

    if Enum.any?(allowed_dirs, &String.starts_with?(path, &1)) do
      :ok
    else
      {:error, "Access denied: path outside allowed directories"}
    end
  end
end
```

## Error Handling

Tools should handle errors gracefully:

```elixir
def run(arguments) do
  case arguments do
    %{"required_field" => value} when is_binary(value) ->
      # Process the value
      process(value)

    %{"required_field" => _} ->
      {:error, {:tool_error, "required_field must be a string"}}

    _ ->
      {:error, {:tool_error, "Missing required_field parameter"}}
  end
end

defp process(value) do
  try do
    result = risky_operation(value)
    {:ok, %{result: result}}
  rescue
    e ->
      Logger.error("Tool error: #{Exception.message(e)}")
      {:error, {:tool_error, "Operation failed"}}
  end
end
```

## Testing Tools

Tools are easy to unit test:

```elixir
defmodule MyApp.Tools.CalculatorTest do
  use ExUnit.Case, async: true

  alias MyApp.Tools.Calculator

  describe "run/1" do
    test "adds two numbers" do
      args = %{"operation" => "add", "a" => 5, "b" => 3}

      assert {:ok, %{result: 8}} = Calculator.run(args)
    end

    test "handles division by zero" do
      args = %{"operation" => "divide", "a" => 10, "b" => 0}

      assert {:error, {:tool_error, _}} = Calculator.run(args)
    end
  end

  describe "descriptor/0" do
    test "returns valid tool descriptor" do
      descriptor = Calculator.descriptor()

      assert descriptor.type == "function"
      assert descriptor.function.name == "calculator"
      assert is_list(descriptor.function.parameters.required)
    end
  end
end
```

## Best Practices

### 1. Keep Tools Focused

One tool, one purpose:

```elixir
# Good: Specific purpose
defmodule GetWeather do ... end
defmodule GetForecast do ... end

# Avoid: Too broad
defmodule WeatherOperations do ... end
```

### 2. Validate Inputs

Always validate parameters:

```elixir
def run(%{"email" => email}) do
  case validate_email(email) do
    :ok -> send_email(email)
    :error -> {:error, {:tool_error, "Invalid email format"}}
  end
end
```

### 3. Provide Clear Errors

Help the LLM understand what went wrong:

```elixir
{:error, {:tool_error, "User not found: #{user_id}"}}
{:error, {:tool_error, "Invalid date format. Use YYYY-MM-DD"}}
{:error, {:tool_error, "Rate limit exceeded. Try again in 60 seconds"}}
```

### 4. Return Structured Data

Make results easy for LLMs to parse:

```elixir
{:ok, %{
  success: true,
  data: %{
    user: %{name: "Alice", age: 30},
    timestamp: DateTime.utc_now()
  }
}}
```

### 5. Log Tool Usage

Track tool execution:

```elixir
def run(args) do
  Logger.info("Tool called with: #{inspect(args)}")
  result = execute(args)
  Logger.info("Tool result: #{inspect(result)}")
  result
end
```

## Multiple Tools

LLMs can use multiple tools in one conversation:

```elixir
tools = [
  DateResolver,
  CurrentDateTime,
  Calculator,
  Weather
]

messages = [
  Message.user("""
  What's the date in 5 days, and what will the
  weather be like in Paris?
  """)
]

{:ok, response} = Broker.generate(broker, messages, tools)
# LLM will call both DateResolver and Weather tools
```

## See Also

- [Getting Started](getting_started.html)
- [Broker Guide](broker.html)
- [DateResolver API](Mojentic.LLM.Tools.DateResolver.html)
- [Tool Behaviour](Mojentic.LLM.Tools.Tool.html)
