defmodule Mojentic.Context.SharedWorkingMemoryTest do
  use ExUnit.Case, async: true

  alias Mojentic.Context.SharedWorkingMemory

  doctest SharedWorkingMemory

  describe "new/0" do
    test "creates empty memory" do
      memory = SharedWorkingMemory.new()

      assert %SharedWorkingMemory{working_memory: %{}} = memory
      assert SharedWorkingMemory.get_working_memory(memory) == %{}
    end
  end

  describe "new/1" do
    test "creates memory with initial data" do
      initial = %{"user" => "Alice", "count" => 42}
      memory = SharedWorkingMemory.new(initial)

      assert SharedWorkingMemory.get_working_memory(memory) == initial
    end

    test "creates memory with nested maps" do
      initial = %{
        "user" => %{
          "name" => "Bob",
          "preferences" => %{
            "theme" => "dark"
          }
        }
      }

      memory = SharedWorkingMemory.new(initial)

      assert SharedWorkingMemory.get_working_memory(memory) == initial
    end
  end

  describe "get_working_memory/1" do
    test "returns current memory" do
      data = %{"key" => "value"}
      memory = SharedWorkingMemory.new(data)

      assert SharedWorkingMemory.get_working_memory(memory) == data
    end

    test "returns empty map for new memory" do
      memory = SharedWorkingMemory.new()

      assert SharedWorkingMemory.get_working_memory(memory) == %{}
    end
  end

  describe "merge_to_working_memory/2" do
    test "merges new top-level keys" do
      memory = SharedWorkingMemory.new(%{"a" => 1})
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{"b" => 2})

      assert SharedWorkingMemory.get_working_memory(memory) == %{"a" => 1, "b" => 2}
    end

    test "overwrites existing top-level values" do
      memory = SharedWorkingMemory.new(%{"count" => 1})
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{"count" => 2})

      assert SharedWorkingMemory.get_working_memory(memory) == %{"count" => 2}
    end

    test "deep merges nested maps" do
      memory = SharedWorkingMemory.new(%{"user" => %{"name" => "Alice", "age" => 30}})

      memory =
        SharedWorkingMemory.merge_to_working_memory(memory, %{"user" => %{"city" => "NYC"}})

      expected = %{"user" => %{"name" => "Alice", "age" => 30, "city" => "NYC"}}
      assert SharedWorkingMemory.get_working_memory(memory) == expected
    end

    test "deep merges multiple levels" do
      memory =
        SharedWorkingMemory.new(%{
          "user" => %{
            "profile" => %{
              "name" => "Alice"
            }
          }
        })

      memory =
        SharedWorkingMemory.merge_to_working_memory(memory, %{
          "user" => %{
            "profile" => %{
              "age" => 30
            }
          }
        })

      expected = %{
        "user" => %{
          "profile" => %{
            "name" => "Alice",
            "age" => 30
          }
        }
      }

      assert SharedWorkingMemory.get_working_memory(memory) == expected
    end

    test "overwrites non-map values in nested structure" do
      memory = SharedWorkingMemory.new(%{"user" => %{"status" => "active"}})

      memory =
        SharedWorkingMemory.merge_to_working_memory(memory, %{"user" => %{"status" => "inactive"}})

      expected = %{"user" => %{"status" => "inactive"}}
      assert SharedWorkingMemory.get_working_memory(memory) == expected
    end

    test "merges empty map" do
      memory = SharedWorkingMemory.new(%{"a" => 1})
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{})

      assert SharedWorkingMemory.get_working_memory(memory) == %{"a" => 1}
    end

    test "merges into empty memory" do
      memory = SharedWorkingMemory.new()
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{"new" => "data"})

      assert SharedWorkingMemory.get_working_memory(memory) == %{"new" => "data"}
    end

    test "preserves original memory immutability" do
      original = SharedWorkingMemory.new(%{"original" => "data"})
      updated = SharedWorkingMemory.merge_to_working_memory(original, %{"new" => "data"})

      assert SharedWorkingMemory.get_working_memory(original) == %{"original" => "data"}

      assert SharedWorkingMemory.get_working_memory(updated) == %{
               "original" => "data",
               "new" => "data"
             }
    end
  end

  describe "merge_to_working_memory/2 with complex scenarios" do
    test "merges lists (overwrites)" do
      memory = SharedWorkingMemory.new(%{"items" => [1, 2, 3]})
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{"items" => [4, 5]})

      assert SharedWorkingMemory.get_working_memory(memory) == %{"items" => [4, 5]}
    end

    test "merges mixed types" do
      memory =
        SharedWorkingMemory.new(%{
          "string" => "text",
          "number" => 42,
          "boolean" => true,
          "list" => [1, 2],
          "map" => %{"nested" => "value"}
        })

      memory =
        SharedWorkingMemory.merge_to_working_memory(memory, %{
          "string" => "updated",
          "map" => %{"additional" => "field"}
        })

      expected = %{
        "string" => "updated",
        "number" => 42,
        "boolean" => true,
        "list" => [1, 2],
        "map" => %{"nested" => "value", "additional" => "field"}
      }

      assert SharedWorkingMemory.get_working_memory(memory) == expected
    end

    test "user profile scenario from Python example" do
      memory =
        SharedWorkingMemory.new(%{
          "User" => %{
            "name" => "Stacey",
            "age" => 56
          }
        })

      # User mentions pets
      memory =
        SharedWorkingMemory.merge_to_working_memory(memory, %{
          "User" => %{
            "pets" => %{
              "dog" => "Boomer",
              "cats" => ["Spot", "Beau"]
            }
          }
        })

      expected = %{
        "User" => %{
          "name" => "Stacey",
          "age" => 56,
          "pets" => %{
            "dog" => "Boomer",
            "cats" => ["Spot", "Beau"]
          }
        }
      }

      assert SharedWorkingMemory.get_working_memory(memory) == expected
    end
  end
end
