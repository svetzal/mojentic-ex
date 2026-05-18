defmodule Mojentic.Realtime.OpenAIGateway do
  @moduledoc """
  Gateway against OpenAI's Realtime API over WebSocket.

  Each `open/3` call provisions a new transport process. The returned
  pid is the only stateful surface; subscribers receive
  `{:realtime_message, parsed}` and `{:realtime_close, reason}`
  tuples.
  """

  @behaviour Mojentic.Realtime.Gateway

  alias Mojentic.Realtime.MintTransport
  alias Mojentic.Realtime.Schemas

  @default_url "wss://api.openai.com/v1/realtime"

  defstruct api_key: nil,
            base_url: @default_url,
            transport: MintTransport

  @type t :: %__MODULE__{
          api_key: String.t() | nil,
          base_url: String.t(),
          transport: module()
        }

  @doc """
  Construct a new gateway. If `:api_key` is omitted, falls back to the
  `OPENAI_API_KEY` environment variable.
  """
  def new(opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

    unless api_key do
      raise ArgumentError, "OpenAI realtime gateway requires :api_key or OPENAI_API_KEY"
    end

    %__MODULE__{
      api_key: api_key,
      base_url: Keyword.get(opts, :base_url, @default_url),
      transport: Keyword.get(opts, :transport, MintTransport)
    }
  end

  def open(%__MODULE__{} = gateway, model, _config, correlation_id) do
    url = gateway.base_url <> "?model=" <> URI.encode(model)

    headers = [
      {"authorization", "Bearer #{gateway.api_key}"},
      {"openai-beta", "realtime=v1"}
    ]

    headers =
      case correlation_id do
        nil -> headers
        cid -> [{"x-correlation-id", cid} | headers]
      end

    case gateway.transport.connect(url, headers, []) do
      {:ok, pid} ->
        gateway.transport.subscribe(pid, self())
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def open(model, config, correlation_id) when is_binary(model) do
    open(new(), model, config, correlation_id)
  end

  @doc """
  Pure helper to validate and parse a server event payload.
  Re-exported so tests can drive the gateway with scripted messages.
  """
  def parse_message(map), do: Schemas.parse_server_event(map)
end
