defmodule Mojentic.Context.SharedWorkingMemory do
  @moduledoc """
  A shared working memory context for agents.

  SharedWorkingMemory provides a simple key-value store that multiple agents
  can read from and write to, enabling knowledge sharing and persistence
  across agent interactions.

  ## Features

  - **Shared Context** - Multiple agents can access the same memory
  - **Merge Updates** - New information is merged into existing memory
  - **Simple API** - Get and merge operations for easy use

  ## Usage

      # Initialize with user data
      memory = SharedWorkingMemory.new(%{
        "User" => %{
          "name" => "Alice",
          "age" => 30
        }
      })

      # Retrieve current memory
      current = SharedWorkingMemory.get_working_memory(memory)

      # Merge new information
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{
        "User" => %{
          "pets" => ["dog", "cat"]
        }
      })

  ## Examples

      # Create memory with initial data
      memory = SharedWorkingMemory.new(%{
        "preferences" => %{"theme" => "dark"}
      })

      # Add new information
      memory = SharedWorkingMemory.merge_to_working_memory(memory, %{
        "preferences" => %{"language" => "elixir"},
        "history" => []
      })

      # Retrieve all memory
      all_data = SharedWorkingMemory.get_working_memory(memory)
      #=> %{
      #     "preferences" => %{"theme" => "dark", "language" => "elixir"},
      #     "history" => []
      #   }

  """

  @type t :: %__MODULE__{
          working_memory: map()
        }

  defstruct working_memory: %{}

  @doc """
  Creates a new SharedWorkingMemory with optional initial memory.

  ## Parameters

  - `initial_memory` - Map of initial working memory (default: %{})

  ## Examples

      iex> SharedWorkingMemory.new()
      %SharedWorkingMemory{working_memory: %{}}

      iex> SharedWorkingMemory.new(%{"user" => "Alice"})
      %SharedWorkingMemory{working_memory: %{"user" => "Alice"}}

  """
  def new(initial_memory \\ %{}) when is_map(initial_memory) do
    %__MODULE__{working_memory: initial_memory}
  end

  @doc """
  Retrieves the current working memory.

  ## Parameters

  - `memory` - The SharedWorkingMemory instance

  ## Returns

  The current working memory map.

  ## Examples

      iex> memory = SharedWorkingMemory.new(%{"key" => "value"})
      iex> SharedWorkingMemory.get_working_memory(memory)
      %{"key" => "value"}

  """
  def get_working_memory(%__MODULE__{working_memory: working_memory}) do
    working_memory
  end

  @doc """
  Merges new data into the working memory.

  Performs a deep merge where nested maps are merged recursively.
  Non-map values at the same key are overwritten by the new value.

  ## Parameters

  - `memory` - The SharedWorkingMemory instance
  - `new_data` - Map of new data to merge

  ## Returns

  Updated SharedWorkingMemory instance.

  ## Examples

      iex> memory = SharedWorkingMemory.new(%{"a" => %{"b" => 1}})
      iex> memory = SharedWorkingMemory.merge_to_working_memory(memory, %{"a" => %{"c" => 2}})
      iex> SharedWorkingMemory.get_working_memory(memory)
      %{"a" => %{"b" => 1, "c" => 2}}

      iex> memory = SharedWorkingMemory.new(%{"count" => 1})
      iex> memory = SharedWorkingMemory.merge_to_working_memory(memory, %{"count" => 2})
      iex> SharedWorkingMemory.get_working_memory(memory)
      %{"count" => 2}

  """
  def merge_to_working_memory(%__MODULE__{working_memory: current} = memory, new_data)
      when is_map(new_data) do
    merged = deep_merge(current, new_data)
    %{memory | working_memory: merged}
  end

  # Deep merge helper - recursively merges nested maps
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        deep_merge(left_val, right_val)
      else
        right_val
      end
    end)
  end

  defp deep_merge(_left, right), do: right
end
