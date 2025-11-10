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

  - `arguments`: Map of argument name to value

  ## Returns

  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  """
  @callback run(arguments :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Returns the tool descriptor for the LLM.

  The descriptor includes the tool's name, description, and
  parameter schema in JSON Schema format.

  """
  @callback descriptor() :: descriptor()

  @doc """
  Returns the tool's name from its descriptor.

  ## Examples

      iex> Tool.name(WeatherTool)
      "get_weather"

  """
  def name(tool) do
    tool.descriptor().function.name
  end

  @doc """
  Returns the tool's description from its descriptor.

  ## Examples

      iex> Tool.description(WeatherTool)
      "Get current weather for a location"

  """
  def description(tool) do
    tool.descriptor().function.description
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

  Delegates to the tool's run/1 callback.

  ## Examples

      iex> Tool.run(WeatherTool, %{"location" => "SF"})
      {:ok, %{location: "SF", temperature: 22, condition: "sunny"}}

  """
  def run(tool, arguments) do
    tool.run(arguments)
  end
end
