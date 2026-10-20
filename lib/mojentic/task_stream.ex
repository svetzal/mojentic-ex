defmodule Mojentic.TaskStream do
  @moduledoc false

  # Internal scheduling boundary; callers retain the public runner API.
  @callback async_stream(Enumerable.t(), (term() -> term()), keyword()) :: Enumerable.t()

  def async_stream(enumerable, fun, options) do
    implementation = Application.get_env(:mojentic, :internal_task_stream, Task)
    implementation.async_stream(enumerable, fun, options)
  end
end
