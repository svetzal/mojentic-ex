defmodule Mojentic.Realtime.Gateway do
  @moduledoc """
  Behaviour for realtime voice gateways.

  Sibling to `Mojentic.LLM.Gateway`: the chat-completions gateway is
  request/response; this one opens a duplex session and yields a
  stream of normalised events.
  """

  alias Mojentic.Realtime.Config

  @doc """
  Open a realtime session. Returns the transport pid on success;
  callers subscribe to it via `Transport.subscribe/2` for inbound
  events.
  """
  @callback open(
              model :: String.t(),
              config :: Config.t(),
              correlation_id :: String.t() | nil
            ) :: {:ok, pid()} | {:error, term()}
end
