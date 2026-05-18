defmodule Mojentic.LLM.Tools.ToolCallExecution do
  @moduledoc """
  A single tool call to execute, identified by an opaque id.

  The id is preserved on the matching `Mojentic.LLM.Tools.ToolCallOutcome`
  so callers can pair calls and outcomes deterministically.
  """

  defstruct [:id, :name, :args]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          args: map()
        }

  def new(id, name, args) when is_binary(id) and is_binary(name) and is_map(args) do
    %__MODULE__{id: id, name: name, args: args}
  end
end

defmodule Mojentic.LLM.Tools.ToolCallOutcome do
  @moduledoc """
  Outcome of executing a single tool call.

  Discriminated by `:ok?` — `true` means the tool returned a result,
  `false` means the tool returned an error tuple or raised.
  """

  defstruct [:id, :name, :ok?, :result, :error, :duration_ms]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          ok?: boolean(),
          result: term() | nil,
          error: term() | nil,
          duration_ms: number()
        }
end
