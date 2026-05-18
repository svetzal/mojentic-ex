defmodule Mojentic.LLM.Tools.RunContextTest do
  use ExUnit.Case, async: true

  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.LLM.Tools.ToolCallOutcome
  alias Mojentic.LLM.Tools.ToolInvocation

  describe "new/1" do
    test "returns a RunContext struct" do
      ctx = RunContext.new(correlation_id: "abc", source: "test")

      assert %RunContext{} = ctx
      assert ctx.correlation_id == "abc"
      assert ctx.source == "test"
    end

    test "defaults cancel_ref to nil" do
      ctx = RunContext.new()

      assert is_nil(ctx.cancel_ref)
    end
  end

  describe "cancelled?/1" do
    test "returns false when cancel_ref is nil" do
      ctx = RunContext.new()

      refute RunContext.cancelled?(ctx)
    end

    test "returns false when cancelled? flag is set but cancel_ref is nil (flag alone is insufficient)" do
      # The cancelled? struct field is overridden by the cancel_ref: nil guard —
      # cancellation is signalled via atomics.  This test documents the behaviour.
      ctx = %RunContext{cancelled?: true, cancel_ref: nil}

      refute RunContext.cancelled?(ctx)
    end

    test "returns false when atomics ref is zero" do
      ref = :atomics.new(1, signed: false)
      ctx = RunContext.new(cancel_ref: ref)

      refute RunContext.cancelled?(ctx)
    end

    test "returns true when atomics ref is non-zero" do
      ref = :atomics.new(1, signed: false)
      :atomics.put(ref, 1, 1)
      ctx = RunContext.new(cancel_ref: ref)

      assert RunContext.cancelled?(ctx)
    end
  end

  describe "cancel/1" do
    test "signals the atomics ref so cancelled? returns true" do
      ref = :atomics.new(1, signed: false)
      ctx = RunContext.new(cancel_ref: ref)

      refute RunContext.cancelled?(ctx)
      RunContext.cancel(ctx)
      assert RunContext.cancelled?(ctx)
    end

    test "is a no-op when cancel_ref is nil" do
      ctx = RunContext.new()

      assert :ok = RunContext.cancel(ctx)
    end
  end

  describe "on_call_start / on_call_complete callbacks" do
    test "on_call_start is invoked by ToolInvocation" do
      test_pid = self()
      ref = make_ref()

      ctx =
        RunContext.new(
          on_call_start: fn call ->
            send(test_pid, {ref, :started, call.name})
            :ok
          end
        )

      call = ToolCallExecution.new("1", "echo", %{})

      # We drive ToolInvocation directly — just needs a tool list that won't find the tool.
      ToolInvocation.invoke(call, [], ctx)

      assert_receive {^ref, :started, "echo"}
    end

    test "on_call_complete is invoked by ToolInvocation" do
      test_pid = self()
      ref = make_ref()

      ctx =
        RunContext.new(
          on_call_complete: fn outcome ->
            send(test_pid, {ref, :completed, outcome.ok?})
            :ok
          end
        )

      call = ToolCallExecution.new("1", "missing", %{})
      ToolInvocation.invoke(call, [], ctx)

      assert_receive {^ref, :completed, false}
    end
  end

  describe "ToolCallOutcome struct" do
    test "stores expected fields" do
      outcome = %ToolCallOutcome{
        id: "1",
        name: "echo",
        ok?: true,
        result: %{value: 42},
        duration_ms: 5
      }

      assert outcome.id == "1"
      assert outcome.ok?
      assert outcome.result == %{value: 42}
    end
  end
end
