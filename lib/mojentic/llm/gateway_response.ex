defmodule Mojentic.LLM.GatewayResponse do
  @moduledoc """
  Represents a response from an LLM gateway.

  A response can contain text content, a structured object,
  and/or tool calls that the LLM wants to execute.

  ## Examples

      iex> %GatewayResponse{content: "Hello!"}
      %GatewayResponse{content: "Hello!", object: nil, tool_calls: [], thinking: nil, usage: nil, model: nil, finish_reason: nil, metadata: %{}}

      iex> %GatewayResponse{object: %{"answer" => 42}}
      %GatewayResponse{content: nil, object: %{"answer" => 42}, tool_calls: [], thinking: nil, usage: nil, model: nil, finish_reason: nil, metadata: %{}}

  """

  alias Mojentic.LLM.ToolCall

  @type t :: %__MODULE__{
          content: String.t() | nil,
          object: term() | nil,
          tool_calls: [ToolCall.t()],
          thinking: String.t() | nil,
          usage: map() | nil,
          model: String.t() | nil,
          finish_reason: String.t() | nil,
          metadata: map()
        }

  defstruct content: nil,
            object: nil,
            tool_calls: [],
            thinking: nil,
            usage: nil,
            model: nil,
            finish_reason: nil,
            metadata: %{}
end
