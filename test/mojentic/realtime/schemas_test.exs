defmodule Mojentic.Realtime.SchemasTest do
  use ExUnit.Case, async: true

  alias Mojentic.Realtime.Schemas

  describe "parse_server_event/1" do
    test "passes through recognised events with required fields" do
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
  end
end
