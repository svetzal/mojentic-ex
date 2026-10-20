defmodule Mojentic.LLM.MonotonicClock do
  @moduledoc """
  Monotonic millisecond clock boundary for client stream measurements.

  The default uses `System.monotonic_time/1`. Tests may configure a module
  implementing this behaviour as `:mojentic, :monotonic_clock`.
  """
  @callback now() :: integer()

  @doc "Returns monotonic milliseconds; the epoch has no wall-clock meaning."
  @spec now() :: integer()
  def now, do: Mojentic.Clock.monotonic_ms()
end
