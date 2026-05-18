defmodule Mojentic.Realtime.Transport do
  @moduledoc """
  Transport behaviour for the realtime subsystem.

  The gateway owns I/O against this contract so unit tests can replace
  the live WebSocket with a scripted, deterministic transport.
  Production implementation: `Mojentic.Realtime.MintTransport`.
  """

  @callback connect(url :: String.t(), headers :: [{String.t(), String.t()}], opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @callback send(pid(), payload :: map()) :: :ok | {:error, term()}

  @callback close(pid()) :: :ok

  @callback subscribe(pid(), subscriber :: pid()) :: :ok
end
