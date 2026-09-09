defmodule Mojentic.LLM.NativeResponseTest do
  use ExUnit.Case, async: true
  alias Mojentic.LLM.{Broker, GatewayResponse, Message, ToolCall}
  alias Mojentic.LLM.Tools.{ParallelToolRunner, RunContext, ToolCallExecution}

  defmodule Echo do
    def descriptor,
      do: %{
        type: "function",
        function: %{
          name: "echo",
          description: "Echo",
          parameters: %{type: "object", properties: %{}}
        }
      }

    def run(_, args), do: {:ok, args}
  end

  defmodule Wait do
    def descriptor,
      do: %{
        type: "function",
        function: %{
          name: "wait",
          description: "Wait",
          parameters: %{type: "object", properties: %{}}
        }
      }

    def run(_, _),
      do:
        (receive do
           :release -> {:ok, "done"}
         end)
  end

  defmodule Gateway do
    def complete(_, messages, tools, _) do
      send(self(), {:gateway_tools, tools})

      if Enum.any?(messages, &(&1.role == :tool)),
        do: {:ok, %GatewayResponse{content: "done"}},
        else:
          {:ok,
           %GatewayResponse{
             tool_calls: [%ToolCall{id: "native-id", name: "echo", arguments: %{}}]
           }}
    end
  end

  test "returns a native response without dispatch or another provider call" do
    broker = Broker.new("offline", Gateway)

    assert {:ok, %GatewayResponse{tool_calls: [%ToolCall{id: "native-id"}]}} =
             Broker.generate_response(broker, [Message.user("inspect")], [Echo])

    assert_received {:gateway_tools, [Echo]}
    refute_received {:gateway_tools, _}
  end

  test "broker accepts a configured runner and forwards completion context" do
    owner = self()
    context = RunContext.new(on_call_complete: &send(owner, {:outcome, &1}))

    broker =
      Broker.new("offline", Gateway,
        tool_runner: ParallelToolRunner.new(max_concurrency: 1),
        tool_context: context
      )

    assert {:ok, "done"} = Broker.generate(broker, [Message.user("inspect")], [Echo])
    assert_received {:outcome, %{id: "native-id", ok?: true}}
  end

  test "timeout retains call identity and emits its completion callback" do
    owner = self()
    context = RunContext.new(on_call_complete: &send(owner, {:outcome, &1}))
    runner = ParallelToolRunner.new(timeout: 5)

    [outcome] =
      ParallelToolRunner.run_with(
        runner,
        [ToolCallExecution.new("timed-id", "wait", %{})],
        [Wait],
        context
      )

    assert %{id: "timed-id", name: "wait", ok?: false, error: {:task_exit, :timeout}} = outcome
    assert_received {:outcome, ^outcome}
  end
end
