defmodule Mojentic.LLM.Tools.EphemeralTaskManager.Task do
  @moduledoc """
  Represents a task with an identifier, description, and status.

  Tasks follow a state machine that transitions from :pending through
  :in_progress to :completed.
  """

  @type status :: :pending | :in_progress | :completed

  @type t :: %__MODULE__{
          id: pos_integer(),
          description: String.t(),
          status: status()
        }

  @enforce_keys [:id, :description]
  defstruct [:id, :description, status: :pending]

  @doc """
  Creates a new task with the given ID and description.

  ## Examples

      iex> Task.new(1, "Write tests")
      %Task{id: 1, description: "Write tests", status: :pending}

  """
  def new(id, description) when is_integer(id) and is_binary(description) do
    %__MODULE__{
      id: id,
      description: description,
      status: :pending
    }
  end

  @doc """
  Returns the string representation of a task status.

  ## Examples

      iex> Task.status_to_string(:pending)
      "pending"

      iex> Task.status_to_string(:in_progress)
      "in_progress"

  """
  def status_to_string(status) do
    case status do
      :pending -> "pending"
      :in_progress -> "in_progress"
      :completed -> "completed"
    end
  end
end
