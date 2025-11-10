defmodule MojenticTest do
  use ExUnit.Case
  doctest Mojentic

  test "returns version" do
    assert Mojentic.version() == "0.1.0"
  end
end
