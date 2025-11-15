defmodule Mojentic.LLM.Tools.CurrentDatetime do
  @moduledoc """
  Tool for getting the current date and time.

  This tool returns the current datetime with optional formatting.
  It's useful when the LLM needs to know the current time or date.

  ## Examples

      alias Mojentic.LLM.Tools.CurrentDatetime

      tool = CurrentDatetime.new()
      {:ok, result} = CurrentDatetime.run(tool, %{})
      # => {:ok, %{current_datetime: "2025-11-15 14:30:00", timestamp: 1700060400, timezone: "UTC"}}

      {:ok, result} = CurrentDatetime.run(tool, %{"format_string" => "%Y-%m-%d"})
      # => {:ok, %{current_datetime: "2025-11-15", timestamp: 1700060400, timezone: "UTC"}}

  """

  @behaviour Mojentic.LLM.Tools.Tool

  defstruct []

  @doc """
  Creates a new CurrentDatetime tool instance.
  """
  def new do
    %__MODULE__{}
  end

  @impl true
  def run(%__MODULE__{}, arguments) do
    format_string = Map.get(arguments, "format_string", "%Y-%m-%d %H:%M:%S")
    now = DateTime.utc_now()

    formatted_time =
      case format_datetime(now, format_string) do
        {:ok, formatted} -> formatted
        {:error, _} -> DateTime.to_string(now)
      end

    {:ok,
     %{
       current_datetime: formatted_time,
       timestamp: DateTime.to_unix(now),
       timezone: now.time_zone
     }}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "get_current_datetime",
        description:
          "Get the current date and time. Useful when you need to know the current time or date.",
        parameters: %{
          type: "object",
          properties: %{
            format_string: %{
              type: "string",
              description:
                "Format string for the datetime (e.g., '%Y-%m-%d %H:%M:%S', '%A, %B %d, %Y'). Default is ISO format."
            }
          },
          required: []
        }
      }
    }
  end

  # Private helper to format datetime using Python-style format codes
  defp format_datetime(datetime, format_string) do
    # Convert Python strftime codes to Elixir Calendar.strftime format
    # This is a simplified version - full compatibility would require more mappings
    try do
      formatted = Calendar.strftime(datetime, format_string)
      {:ok, formatted}
    rescue
      _ -> {:error, :invalid_format}
    end
  end
end
