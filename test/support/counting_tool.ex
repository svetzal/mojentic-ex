defmodule Mojentic.TestSupport.CountingTool do
  @behaviour Mojentic.LLM.Tools.Tool
  defstruct [:owner, result: {:ok, "tool-result-secret"}]
  @impl true
  def run(tool, args) do
    send(tool.owner, {:tool_executed, args})
    tool.result
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{name: "count", description: "count", parameters: %{type: "object"}}
    }
  end
end
