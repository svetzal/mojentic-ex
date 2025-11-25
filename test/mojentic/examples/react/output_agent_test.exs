defmodule Mojentic.Examples.React.OutputAgentTest do
  use ExUnit.Case, async: true

  alias Mojentic.Examples.React.Events.InvokeThinking
  alias Mojentic.Examples.React.Models.CurrentContext
  alias Mojentic.Examples.React.OutputAgent

  describe "receive_event_async/2" do
    test "logs event and returns empty list" do
      context = CurrentContext.new("What is the date?")

      event = %InvokeThinking{
        source: __MODULE__,
        context: context
      }

      assert {:ok, []} = OutputAgent.receive_event_async(nil, event)
    end

    test "handles any event type" do
      # Test with a simple map that has __struct__
      event = %{__struct__: SomeEvent, data: "test"}

      # Should not crash, just log
      assert {:ok, []} = OutputAgent.receive_event_async(nil, event)
    end
  end
end
