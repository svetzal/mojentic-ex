defmodule Mojentic.Agents.BaseAsyncAgentTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.BaseAsyncAgent
  alias Mojentic.Event

  defmodule TestEvent do
    use Event
    defstruct [:source, :correlation_id, :data]
  end

  defmodule SimpleAsyncAgent do
    @behaviour BaseAsyncAgent

    @impl true
    def receive_event_async(%TestEvent{data: "error"}) do
      {:error, :processing_failed}
    end

    def receive_event_async(%TestEvent{data: data} = event) do
      result_event = %TestEvent{
        source: __MODULE__,
        correlation_id: event.correlation_id,
        data: "processed: #{data}"
      }

      {:ok, [result_event]}
    end
  end

  describe "BaseAsyncAgent behaviour" do
    test "implements receive_event_async callback" do
      assert function_exported?(SimpleAsyncAgent, :receive_event_async, 1)
    end

    test "returns {:ok, events} on success" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "test-123",
        data: "test"
      }

      assert {:ok, [result]} = SimpleAsyncAgent.receive_event_async(event)
      assert result.data == "processed: test"
      assert result.correlation_id == "test-123"
    end

    test "returns {:error, reason} on failure" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "test-123",
        data: "error"
      }

      assert {:error, :processing_failed} = SimpleAsyncAgent.receive_event_async(event)
    end

    test "preserves correlation_id in output events" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "preserve-me",
        data: "test"
      }

      {:ok, [result]} = SimpleAsyncAgent.receive_event_async(event)
      assert result.correlation_id == "preserve-me"
    end
  end

  defmodule MultiEventAgent do
    @behaviour BaseAsyncAgent

    @impl true
    def receive_event_async(%TestEvent{} = event) do
      events = [
        %TestEvent{source: __MODULE__, correlation_id: event.correlation_id, data: "event1"},
        %TestEvent{source: __MODULE__, correlation_id: event.correlation_id, data: "event2"}
      ]

      {:ok, events}
    end
  end

  describe "multiple event generation" do
    test "can return multiple events" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "multi-123",
        data: "test"
      }

      {:ok, events} = MultiEventAgent.receive_event_async(event)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.correlation_id == "multi-123"))
    end
  end

  defmodule NoEventAgent do
    @behaviour BaseAsyncAgent

    @impl true
    def receive_event_async(_event) do
      {:ok, []}
    end
  end

  describe "empty event list" do
    test "can return empty event list" do
      event = %TestEvent{source: __MODULE__, data: "test"}

      assert {:ok, []} = NoEventAgent.receive_event_async(event)
    end
  end
end
