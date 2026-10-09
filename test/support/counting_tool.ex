defmodule Mojentic.TestSupport.CountingTool do
  @behaviour Mojentic.LLM.Tools.Tool
  defstruct [:owner]
  @impl true
  def run(tool, args) do
    send(tool.owner, {:tool_executed, args})
    {:ok, "tool-result-secret"}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{name: "count", description: "count", parameters: %{type: "object"}}
    }
  end
end
