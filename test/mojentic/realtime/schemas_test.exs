defmodule Mojentic.Realtime.SchemasTest do
  use ExUnit.Case, async: true

  alias Mojentic.Realtime.Schemas

  describe "parse_server_event/1" do
    test "passes through events that have a type key" do
      raw = %{"type" => "session.created", "session" => %{"id" => "sess_1"}}

      assert Schemas.parse_server_event(raw) == raw
    end

    test "passes through unknown event types" do
      raw = %{"type" => "session.something_new", "payload" => true}

      assert Schemas.parse_server_event(raw) == raw
    end

    test "returns unknown marker for type-less payload" do
      assert Schemas.parse_server_event(%{"no_type" => true}) == %{"type" => "unknown"}
    end

    test "tolerates audio.delta alias" do
      raw = %{"type" => "response.output_audio.delta", "response_id" => "r1", "delta" => "AAAA"}

      assert Schemas.parse_server_event(raw) == raw
    end

    test "returns unknown for non-map input" do
      assert Schemas.parse_server_event("not a map") == %{"type" => "unknown"}
    end
  end

  describe "valid?/1" do
    test "returns true for well-formed known event" do
      raw = %{"type" => "session.created", "session" => %{"id" => "sess_1"}}

      assert Schemas.valid?(raw)
    end

    test "returns false when required field is missing" do
      raw = %{"type" => "session.created", "session" => %{}}

      refute Schemas.valid?(raw)
    end

    test "returns true for unknown event types (forward-compat)" do
      assert Schemas.valid?(%{"type" => "some.future_event", "data" => 1})
    end

    test "returns false for non-map" do
      refute Schemas.valid?("not a map")
    end
  end

  describe "known_types/0" do
    test "includes core event types" do
      types = Schemas.known_types()

      assert "session.created" in types
      assert "response.done" in types
      assert "error" in types
    end
  end
end
