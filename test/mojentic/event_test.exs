defmodule Mojentic.EventTest do
  use ExUnit.Case, async: true

  alias Mojentic.Event
  alias Mojentic.Events.TerminateEvent

  describe "Event behaviour" do
    defmodule TestEvent do
      use Event

      @type t :: %__MODULE__{
              source: module(),
              correlation_id: String.t() | nil,
              data: String.t()
            }

      defstruct [:source, :correlation_id, :data]
    end

    test "defines event with required fields" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: "test-123",
        data: "test data"
      }

      assert event.source == __MODULE__
      assert event.correlation_id == "test-123"
      assert event.data == "test data"
    end

    test "allows nil correlation_id" do
      event = %TestEvent{
        source: __MODULE__,
        correlation_id: nil,
        data: "test"
      }

      assert is_nil(event.correlation_id)
    end
  end

  describe "Event.new/2 with keyword list" do
    defmodule SimpleEvent do
      use Event
      defstruct [:source, :correlation_id, :message]
    end

    test "creates event with provided correlation_id" do
      event =
        Event.new(SimpleEvent, source: __MODULE__, correlation_id: "custom-123", message: "hello")

      assert event.source == __MODULE__
      assert event.correlation_id == "custom-123"
      assert event.message == "hello"
    end

    test "auto-generates correlation_id if not provided" do
      event = Event.new(SimpleEvent, source: __MODULE__, message: "hello")

      assert event.source == __MODULE__
      assert is_binary(event.correlation_id)
      assert String.length(event.correlation_id) == 36
    end

    test "preserves all custom fields" do
      event = Event.new(SimpleEvent, source: __MODULE__, message: "test message")

      assert event.message == "test message"
    end
  end

  describe "Event.new/2 with map" do
    defmodule MapEvent do
      use Event
      defstruct [:source, :correlation_id, :value]
    end

    test "creates event from map with correlation_id" do
      attrs = %{source: __MODULE__, correlation_id: "map-123", value: 42}
      event = Event.new(MapEvent, attrs)

      assert event.source == __MODULE__
      assert event.correlation_id == "map-123"
      assert event.value == 42
    end

    test "auto-generates correlation_id from map" do
      attrs = %{source: __MODULE__, value: 42}
      event = Event.new(MapEvent, attrs)

      assert event.source == __MODULE__
      assert is_binary(event.correlation_id)
      assert event.value == 42
    end
  end

  describe "TerminateEvent" do
    test "is a valid event type" do
      event = %TerminateEvent{source: __MODULE__}

      assert event.source == __MODULE__
      assert is_nil(event.correlation_id)
    end

    test "can be created with Event.new/2" do
      event = Event.new(TerminateEvent, source: __MODULE__)

      assert event.source == __MODULE__
      assert is_binary(event.correlation_id)
    end
  end
end
