defmodule Mojentic.LLM.Tools.ToolInvocationTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.LLM.Tools.ToolInvocation

  defmodule EchoTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, args), do: {:ok, %{echo: Map.get(args, "value", "")}}

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "echo",
          description: "Echo input",
          parameters: %{type: "object", properties: %{value: %{type: "string"}}, required: []}
        }
      }
    end
  end

  defmodule ErrorTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, _args), do: {:error, :deliberate_error}

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "error_tool",
          description: "Returns error",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  defmodule RaisingTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, _args), do: raise("boom")

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "raising",
          description: "Always raises",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  defmodule BareTool do
    @behaviour Mojentic.LLM.Tools.Tool

    # Returns bare value instead of {:ok, _}
    @impl true
    def run(_tool, _args), do: "bare result"

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "bare",
          description: "Returns bare value",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  defmodule CtxAwareTool do
    @behaviour Mojentic.LLM.Tools.Tool

    @impl true
    def run(_tool, _args), do: {:ok, %{ctx: false}}

    def run(_tool, _args, %RunContext{} = _ctx), do: {:ok, %{ctx: true}}

    @impl true
    def descriptor do
      %{
        type: "function",
        function: %{
          name: "ctx_aware",
          description: "Detects whether ctx was passed",
          parameters: %{type: "object", properties: %{}, required: []}
        }
      }
    end
  end

  describe "invoke/3" do
    test "returns ok outcome for successful tool" do
      call = ToolCallExecution.new("1", "echo", %{"value" => "hi"})
      outcome = ToolInvocation.invoke(call, [EchoTool])

      assert outcome.ok?
      assert outcome.result.echo == "hi"
      assert outcome.id == "1"
      assert outcome.name == "echo"
    end

    test "returns tool_not_found when tool is missing" do
      call = ToolCallExecution.new("1", "missing", %{})
      outcome = ToolInvocation.invoke(call, [EchoTool])

      refute outcome.ok?
      assert outcome.error == {:tool_not_found, "missing"}
    end

    test "captures error tuple as ok?: false" do
      call = ToolCallExecution.new("1", "error_tool", %{})
      outcome = ToolInvocation.invoke(call, [ErrorTool])

      refute outcome.ok?
      assert outcome.error == :deliberate_error
    end

    test "captures raises as exception outcome" do
      call = ToolCallExecution.new("1", "raising", %{})
      outcome = ToolInvocation.invoke(call, [RaisingTool])

      refute outcome.ok?
      assert match?({:exception, _}, outcome.error)
    end

    test "wraps bare return value as ok?: true" do
      call = ToolCallExecution.new("1", "bare", %{})
      outcome = ToolInvocation.invoke(call, [BareTool])

      assert outcome.ok?
      assert outcome.result == "bare result"
    end

    test "passes context to run/3 when available" do
      ctx = RunContext.new()
      call = ToolCallExecution.new("1", "ctx_aware", %{})
      outcome = ToolInvocation.invoke(call, [CtxAwareTool], ctx)

      assert outcome.ok?
      assert outcome.result.ctx == true
    end

    test "calls run/2 when context is nil even for ctx-aware tool" do
      call = ToolCallExecution.new("1", "ctx_aware", %{})
      outcome = ToolInvocation.invoke(call, [CtxAwareTool], nil)

      assert outcome.ok?
      assert outcome.result.ctx == false
    end

    test "records duration_ms" do
      call = ToolCallExecution.new("1", "echo", %{"value" => "x"})
      outcome = ToolInvocation.invoke(call, [EchoTool])

      assert is_number(outcome.duration_ms)
      assert outcome.duration_ms >= 0
    end
  end
end
