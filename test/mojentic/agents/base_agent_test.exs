defmodule Mojentic.Agents.BaseAgentTest do
  use ExUnit.Case, async: true

  alias Mojentic.Agents.BaseAgent
  alias Mojentic.Event

  defmodule TestEvent do
    use Event
    defstruct [:source, :correlation_id, :data]
  end

  describe "BaseAgent behaviour" do
    defmodule SimpleAgent do
      @behaviour BaseAgent

      @impl true
      def receive_event(%TestEvent{data: data} = event) do
        result_event = %TestEvent{
          source: __MODULE__,
          correlation_id: event.correlation_id,
          data: "processed: #{data}"
        }

        [result_event]
      end
    end

    test "implements receive_event callback" do
      assert function_exported?(SimpleAgent, :receive_event, 1)
    end

    test "returns list of events on success" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "test-123",
        data: "test"
      }

      result = SimpleAgent.receive_event(event)
      assert is_list(result)
      assert length(result) == 1

      [result_event] = result
      assert result_event.data == "processed: test"
      assert result_event.correlation_id == "test-123"
    end

    test "preserves correlation_id in output events" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "preserve-me",
        data: "test"
      }

      [result] = SimpleAgent.receive_event(event)
      assert result.correlation_id == "preserve-me"
    end
  end

  describe "multiple event generation" do
    defmodule MultiEventAgent do
      @behaviour BaseAgent

      @impl true
      def receive_event(%TestEvent{} = event) do
        [
          %TestEvent{source: __MODULE__, correlation_id: event.correlation_id, data: "event1"},
          %TestEvent{source: __MODULE__, correlation_id: event.correlation_id, data: "event2"}
        ]
      end
    end

    test "can return multiple events" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "multi-123",
        data: "test"
      }

      events = MultiEventAgent.receive_event(event)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.correlation_id == "multi-123"))
    end
  end

  describe "empty event list" do
    defmodule NoEventAgent do
      @behaviour BaseAgent

      @impl true
      def receive_event(_event) do
        []
      end
    end

    test "can return empty event list" do
      event = %TestEvent{source: __MODULE__, data: "test"}

      assert [] = NoEventAgent.receive_event(event)
    end
  end

  describe "__using__ macro" do
    defmodule DefaultAgent do
      use BaseAgent
    end

    test "provides default receive_event implementation" do
      assert function_exported?(DefaultAgent, :receive_event, 1)
    end

    test "default implementation returns empty list" do
      event = %TestEvent{source: __MODULE__, data: "test"}

      assert [] = DefaultAgent.receive_event(event)
    end

    defmodule OverriddenAgent do
      use BaseAgent

      @impl true
      def receive_event(%TestEvent{} = event) do
        [%TestEvent{source: __MODULE__, correlation_id: event.correlation_id, data: "overridden"}]
      end
    end

    test "default implementation can be overridden" do
      event = %TestEvent{source: __MODULE__, data: "test"}

      [result] = OverriddenAgent.receive_event(event)
      assert result.data == "overridden"
    end
  end
end
