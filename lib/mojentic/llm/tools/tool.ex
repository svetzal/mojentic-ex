defmodule Mojentic.LLM.Tools.Tool do
  @moduledoc """
  Behaviour for LLM tool implementations.

  Tools allow LLMs to perform actions or retrieve information
  by calling functions that you define.

  ## Examples

  Implementing a custom tool:

      defmodule WeatherTool do
        @behaviour Mojentic.LLM.Tools.Tool

        @impl true
        def run(arguments) do
          location = Map.get(arguments, "location", "unknown")
          {:ok, %{location: location, temperature: 22, condition: "sunny"}}
        end

        @impl true
        def descriptor do
          %{
            type: "function",
            function: %{
              name: "get_weather",
              description: "Get current weather for a location",
              parameters: %{
                type: "object",
                properties: %{
                  location: %{
                    type: "string",
                    description: "The city or location"
                  }
                },
                required: ["location"]
              }
            }
          }
        end
      end

  """

  @type descriptor :: %{
          type: String.t(),
          function: %{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
        }

  @doc """
  Executes the tool with the given arguments.

  ## Parameters

  - `tool`: The tool struct instance
  - `arguments`: Map of argument name to value

  ## Returns

  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  """
  @callback run(tool :: struct(), arguments :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Returns the tool descriptor for the LLM.

  The descriptor includes the tool's name, description, and
  parameter schema in JSON Schema format.

  """
  @callback descriptor() :: descriptor()

  @doc """
  Returns the tool's name from its descriptor.

  Supports both module-based tools and struct-based tools with instance descriptors.

  ## Examples

      iex> Tool.name(WeatherTool)
      "get_weather"

      iex> tool_instance = ToolWrapper.new(agent: agent, name: "custom", description: "desc")
      iex> Tool.name(tool_instance)
      "custom"

  """
  def name(tool) do
    descriptor(tool).function.name
  end

  @doc """
  Returns the tool's description from its descriptor.

  ## Examples

      iex> Tool.description(WeatherTool)
      "Get current weather for a location"

  """
  def description(tool) do
    descriptor(tool).function.description
  end

  @doc """
  Checks if a tool matches the given name.

  ## Examples

      iex> Tool.matches?(WeatherTool, "get_weather")
      true

      iex> Tool.matches?(WeatherTool, "other_tool")
      false

  """
  def matches?(tool, tool_name) do
    name(tool) == tool_name
  end

  @doc """
  Runs a tool with the given arguments.

  Supports both module-based tools and struct-based tools.

  ## Examples

      iex> Tool.run(WeatherTool, %{"location" => "SF"})
      {:ok, %{location: "SF", temperature: 22, condition: "sunny"}}

      iex> tool = ToolWrapper.new(...)
      iex> Tool.run(tool, %{"input" => "test"})
      {:ok, "response"}

  """
  def run(tool, arguments) when is_atom(tool) do
    # Module-based tool: call run/2 with nil/module as first arg
    # (most tools ignore the first argument or expect the module)
    tool.run(tool, arguments)
  end

  def run(%module{} = tool, arguments) do
    # Struct-based tool: call run/2 with the struct instance
    module.run(tool, arguments)
  end

  @doc """
  Returns the descriptor for a tool.

  Handles both module-based tools (with descriptor/0) and
  struct-based tools (with descriptor/1).

  ## Examples

      iex> Tool.descriptor(WeatherTool)
      %{type: "function", function: %{name: "get_weather", ...}}

      iex> tool = ToolWrapper.new(...)
      iex> Tool.descriptor(tool)
      %{type: "function", function: %{name: "custom_name", ...}}

  """
  def descriptor(tool) when is_atom(tool) do
    # Module-based tool: call descriptor/0
    tool.descriptor()
  end

  def descriptor(%module{} = tool) do
    # Struct-based tool: try descriptor/1, fall back to descriptor/0
    if function_exported?(module, :descriptor, 1) do
      module.descriptor(tool)
    else
      module.descriptor()
    end
  end
end
