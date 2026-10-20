defmodule Mojentic.TestSupport.Clock do
  @moduledoc false
  @behaviour Mojentic.Clock

  # Most tests hold time fixed. Serial tests install a shared counter when
  # workers and their caller need to observe explicit advances together.
  @impl true
  def monotonic_ms do
    case Application.get_env(:mojentic, :test_clock) do
      nil ->
        0

      counter ->
        now = :atomics.get(counter, 1)
        :atomics.put(counter, 2, now)
        now
    end
  end

  @impl true
  def os_time_ms, do: DateTime.to_unix(utc_now(), :millisecond)

  @impl true
  def utc_now, do: DateTime.add(~U[2026-01-01 00:00:00Z], monotonic_ms(), :millisecond)

  @impl true
  def sleep(_milliseconds), do: :ok

  def advance(milliseconds) do
    :atomics.add(Application.fetch_env!(:mojentic, :test_clock), 1, milliseconds)
    :ok
  end

  def last_read do
    :atomics.get(Application.fetch_env!(:mojentic, :test_clock), 2)
  end

  def install do
    Application.put_env(:mojentic, :test_clock, :atomics.new(2, []))
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:mojentic, :test_clock) end)
  end
end
