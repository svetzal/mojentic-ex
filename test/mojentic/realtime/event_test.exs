defmodule Mojentic.Realtime.EventTest do
  use ExUnit.Case, async: true

  alias Mojentic.Realtime.Event

  describe "new/2" do
    test "constructs an event with kind and payload" do
      event = Event.new(:session_opened, %{session_id: "s1"})

      assert event.kind == :session_opened
      assert event.payload == %{session_id: "s1"}
    end

    test "defaults to empty payload" do
      event = Event.new(:session_closed)

      assert event.kind == :session_closed
      assert event.payload == %{}
    end

    test "raises on non-atom kind" do
      assert_raise FunctionClauseError, fn ->
        Event.new("not_an_atom", %{})
      end
    end

    test "raises on non-map payload" do
      assert_raise FunctionClauseError, fn ->
        Event.new(:session_opened, "not a map")
      end
    end
  end

  describe "pattern matching on kind" do
    test "all documented kinds can be pattern matched" do
      kinds = [
        :session_opened,
        :session_updated,
        :session_closed,
        :user_speech_started,
        :user_speech_stopped,
        :user_transcript_delta,
        :user_transcript,
        :assistant_turn_started,
        :assistant_text_delta,
        :assistant_text,
        :assistant_transcript_delta,
        :assistant_transcript,
        :assistant_audio_delta,
        :assistant_turn_completed,
        :tool_call_started,
        :tool_call_args_delta,
        :tool_call_dispatched,
        :tool_call_completed,
        :tool_call_failed,
        :tool_batch_submitted,
        :interrupted,
        :rate_limited,
        :error
      ]

      for kind <- kinds do
        event = Event.new(kind)
        assert %Event{kind: ^kind} = event
      end
    end
  end
end
