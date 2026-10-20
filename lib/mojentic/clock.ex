defmodule Mojentic.Clock do
  @moduledoc false

  # Internal boundary shared by code that has no caller-facing clock option.
  # Existing per-request clock options still take precedence.
  @callback monotonic_ms() :: integer()
  @callback os_time_ms() :: integer()
  @callback utc_now() :: DateTime.t()
  @callback sleep(non_neg_integer()) :: :ok

  def monotonic_ms, do: implementation().monotonic_ms()
  def os_time_ms, do: implementation().os_time_ms()
  def utc_now, do: implementation().utc_now()
  def sleep(milliseconds), do: implementation().sleep(milliseconds)

  defp implementation, do: Application.get_env(:mojentic, :internal_clock, Mojentic.Clock.System)
end

defmodule Mojentic.Clock.System do
  @moduledoc false
  @behaviour Mojentic.Clock

  @impl true
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def os_time_ms, do: System.os_time(:millisecond)

  @impl true
  def utc_now, do: DateTime.utc_now()

  @impl true
  def sleep(milliseconds), do: Process.sleep(milliseconds)
end
