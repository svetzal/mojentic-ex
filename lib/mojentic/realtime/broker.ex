defmodule Mojentic.Realtime.Broker do
  @moduledoc """
  Realtime voice broker — sibling to `Mojentic.LLM.Broker`.

  The broker holds no session state. Each `connect/1` opens a fresh
  transport via the configured gateway, hands the transport to a new
  `Mojentic.Realtime.Session` GenServer, and returns the session pid.

  Subscribers receive vendor-neutral `{:realtime_event, %Event{}}`
  messages by calling `Session.subscribe/2` after `connect/1`.

  Mirrors `RealtimeVoiceBroker` in mojentic-py / mojentic-ts.
  """

  alias Mojentic.LLM.Tools.ParallelToolRunner
  alias Mojentic.Realtime.Config
  alias Mojentic.Realtime.MintTransport
  alias Mojentic.Realtime.OpenAIGateway
  alias Mojentic.Realtime.Session

  defstruct model: nil,
            gateway: nil,
            config: nil,
            tracer: nil,
            tool_runner: ParallelToolRunner,
            transport_module: MintTransport

  @type t :: %__MODULE__{
          model: String.t(),
          gateway: OpenAIGateway.t() | module(),
          config: Config.t(),
          tracer: pid() | atom() | nil,
          tool_runner: module(),
          transport_module: module()
        }

  @doc """
  Build a new broker. `opts`:

  - `:gateway` — gateway struct (e.g. `OpenAIGateway.new(...)`)
  - `:config` — vendor-neutral `RealtimeVoiceConfig`
  - `:tracer` — tracer pid (optional)
  - `:tool_runner` — runner module (default: `ParallelToolRunner`)
  - `:transport_module` — transport module (default: `MintTransport`)
  """
  def new(model, opts \\ []) do
    %__MODULE__{
      model: model,
      gateway: Keyword.fetch!(opts, :gateway),
      config: Keyword.get(opts, :config, Config.new()),
      tracer: Keyword.get(opts, :tracer),
      tool_runner: Keyword.get(opts, :tool_runner, ParallelToolRunner),
      transport_module: Keyword.get(opts, :transport_module, MintTransport)
    }
  end

  @doc """
  Open a new realtime session. Returns `{:ok, session_pid}` or
  `{:error, reason}`. The initial `session.update` is sent before
  returning so callers can immediately drive the session.
  """
  def connect(%__MODULE__{} = broker, overrides \\ []) do
    config = merge_overrides(broker.config, overrides)
    correlation_id = UUID.uuid4()

    with {:ok, transport_pid} <- open_gateway(broker, config, correlation_id),
         {:ok, session_pid} <-
           Session.start_link(
             transport: transport_pid,
             transport_module: broker.transport_module,
             config: config,
             tool_runner: broker.tool_runner,
             tracer: broker.tracer,
             correlation_id: correlation_id
           ),
         :ok <- Session.initialise(session_pid) do
      {:ok, session_pid}
    end
  end

  defp open_gateway(%__MODULE__{gateway: %OpenAIGateway{} = gw} = broker, config, cid) do
    OpenAIGateway.open(gw, broker.model, config, cid)
  end

  defp open_gateway(%__MODULE__{gateway: module} = broker, config, cid) when is_atom(module) do
    module.open(broker.model, config, cid)
  end

  defp merge_overrides(%Config{} = base, []) do
    base
  end

  defp merge_overrides(%Config{} = base, overrides) do
    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end
end
