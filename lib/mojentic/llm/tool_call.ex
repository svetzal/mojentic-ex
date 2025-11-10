defmodule Mojentic.LLM.ToolCall do
  @moduledoc """
  Represents a tool call from an LLM.

  Tool calls contain the tool name, arguments, and optionally an ID
  for tracking purposes.

  ## Examples

      iex> %ToolCall{name: "get_weather", arguments: %{"location" => "SF"}}
      %ToolCall{id: nil, name: "get_weather", arguments: %{"location" => "SF"}}

  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          arguments: map()
        }

  @enforce_keys [:name, :arguments]
  defstruct [:id, :name, :arguments]
end
