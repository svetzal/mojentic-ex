defmodule Mojentic.LLM.GatewayResponse do
  @moduledoc """
  Represents a response from an LLM gateway.

  A response can contain text content, a structured object,
  and/or tool calls that the LLM wants to execute.

  ## Examples

      iex> %GatewayResponse{content: "Hello!"}
      %GatewayResponse{content: "Hello!", object: nil, tool_calls: []}

      iex> %GatewayResponse{object: %{"answer" => 42}}
      %GatewayResponse{content: nil, object: %{"answer" => 42}, tool_calls: []}

  """

  alias Mojentic.LLM.ToolCall

  @type t :: %__MODULE__{
          content: String.t() | nil,
          object: term() | nil,
          tool_calls: [ToolCall.t()]
        }

  defstruct [
    content: nil,
    object: nil,
    tool_calls: []
  ]
end
