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

  defmodule MeteredGateway do
    def complete(_, _, _, _) do
      {:ok,
       %GatewayResponse{
         content: "done",
         usage: %{"input_tokens" => 123, "output_tokens" => 4},
         model: "reported-model",
         finish_reason: "stop",
         metadata: %{usage_provenance: "provider"}
       }}
    end
  end

  test "response trace preserves provider usage independently of the returned receipt" do
    alias Mojentic.Tracer.TracerEvents.LLMResponseTracerEvent
    tracer = start_supervised!(Mojentic.Tracer.TracerSystem)
    broker = Broker.new("configured-model", MeteredGateway, tracer: tracer)
    assert {:ok, response} = Broker.generate_response(broker, [Message.user("hello")])
    [event] = Mojentic.Tracer.get_events(tracer, event_type: LLMResponseTracerEvent)
    assert event.usage == response.usage
    assert event.provider_model == "reported-model"
    assert event.model == "configured-model"
    assert event.finish_reason == "stop"
    assert event.metadata == response.metadata
  end

  defmodule MeteredObjectGateway do
    def complete_object(_, _, _, _) do
      {:ok,
       %GatewayResponse{
         content: "{}",
         object: %{},
         usage: %{"prompt_tokens" => 9, "completion_tokens" => 1},
         model: "reported-model",
         finish_reason: "stop",
         metadata: %{"total_duration" => 42}
       }}
    end
  end

  test "structured response trace preserves provider evidence unchanged" do
    alias Mojentic.Tracer.TracerEvents.LLMResponseTracerEvent
    tracer = start_supervised!(Mojentic.Tracer.TracerSystem)
    broker = Broker.new("configured-model", MeteredObjectGateway, tracer: tracer)
    assert {:ok, %{}} = Broker.generate_object(broker, [Message.user("hello")], %{})
    [event] = Mojentic.Tracer.get_events(tracer, event_type: LLMResponseTracerEvent)
    assert event.usage == %{"prompt_tokens" => 9, "completion_tokens" => 1}
    assert event.provider_model == "reported-model"
    assert event.model == "configured-model"
    assert event.finish_reason == "stop"
    assert event.metadata == %{"total_duration" => 42}
  end

  defmodule EventGateway do
    @evidence %{
      finish_reason: "stop",
      usage: %{"total_tokens" => 12},
      model: "reported-model",
      metadata: %{"total_duration" => 99}
    }

    def complete_stream_events(_, [%Message{content: scenario}], _) do
      case scenario do
        "completed" ->
          [{:content, "par"}, {:content, "tial"}, {:completed, @evidence}]

        "truncated" ->
          [
            {:content, "partial"},
            {:error, {:incomplete_completion, %{@evidence | finish_reason: "length"}}}
          ]

        "provider error" ->
          [{:content, "partial"}, {:error, {:provider_error, %{"code" => "overloaded"}}}]

        "eof" ->
          [{:content, "partial"}]
      end
    end
  end

  describe "single-turn stream traces" do
    alias Mojentic.Tracer.TracerEvents.{LLMCallTracerEvent, LLMResponseTracerEvent}

    test "completion records call and response with the terminal evidence" do
      assert %{call: call, response: response} = trace_stream("completed")
      assert call.model == "configured-model"
      assert call.tools == nil
      assert response.model == "configured-model"
      assert response.content == "partial"
      assert response.usage == %{"total_tokens" => 12}
      assert response.provider_model == "reported-model"
      assert response.finish_reason == "stop"
      assert response.metadata == %{"total_duration" => 99}
    end

    test "incomplete completion records content so far with its evidence" do
      assert %{response: response} = trace_stream("truncated")
      assert response.content == "partial"
      assert response.usage == %{"total_tokens" => 12}
      assert response.provider_model == "reported-model"
      assert response.finish_reason == "length"
      assert response.metadata == %{"total_duration" => 99}
    end

    test "failures without completion evidence record unknown evidence" do
      for scenario <- ["provider error", "eof"] do
        assert %{response: response} = trace_stream(scenario)
        assert response.content == "partial"
        assert response.usage == nil
        assert response.provider_model == nil
        assert response.finish_reason == nil
        assert response.metadata == nil
      end
    end

    test "a gateway without event support fails before any request or trace" do
      tracer = start_supervised!(Mojentic.Tracer.TracerSystem, id: make_ref())
      broker = Broker.new("configured-model", Gateway, tracer: tracer)

      assert [{:error, :stream_events_unsupported}] =
               broker |> Broker.generate_stream_events([Message.user("hi")]) |> Enum.to_list()

      refute_received {:gateway_tools, _}
      assert [] = Mojentic.Tracer.get_events(tracer, event_type: LLMCallTracerEvent)
    end

    defp trace_stream(scenario) do
      tracer = start_supervised!(Mojentic.Tracer.TracerSystem, id: make_ref())
      broker = Broker.new("configured-model", EventGateway, tracer: tracer)
      broker |> Broker.generate_stream_events([Message.user(scenario)]) |> Stream.run()
      [call] = Mojentic.Tracer.get_events(tracer, event_type: LLMCallTracerEvent)
      [response] = Mojentic.Tracer.get_events(tracer, event_type: LLMResponseTracerEvent)
      %{call: call, response: response}
    end
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
