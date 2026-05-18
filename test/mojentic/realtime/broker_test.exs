defmodule Mojentic.Realtime.BrokerTest do
  use ExUnit.Case, async: true

  alias Mojentic.Realtime.Broker
  alias Mojentic.Realtime.Config

  # ---------------------------------------------------------------------------
  # Stub gateway — returns a fake transport pid.
  # ---------------------------------------------------------------------------

  defmodule StubTransport do
    @behaviour Mojentic.Realtime.Transport

    use GenServer

    @impl Mojentic.Realtime.Transport
    def connect(_url, _headers, _opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl Mojentic.Realtime.Transport
    def send(pid, _payload), do: GenServer.call(pid, :send)

    @impl Mojentic.Realtime.Transport
    def close(pid) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
    end

    @impl Mojentic.Realtime.Transport
    def subscribe(pid, subscriber), do: GenServer.call(pid, {:subscribe, subscriber})

    @impl GenServer
    def init(:ok), do: {:ok, %{subscriber: nil}}

    @impl GenServer
    def handle_call(:send, _from, state), do: {:reply, :ok, state}

    def handle_call({:subscribe, pid}, _from, state) do
      {:reply, :ok, %{state | subscriber: pid}}
    end
  end

  defmodule StubGateway do
    @behaviour Mojentic.Realtime.Gateway

    @impl true
    def open(_model, _config, _correlation_id) do
      StubTransport.connect("ws://stub", [], [])
    end
  end

  # ---------------------------------------------------------------------------

  describe "new/2" do
    test "builds a broker with required gateway" do
      broker = Broker.new("gpt-realtime-2", gateway: StubGateway)

      assert broker.model == "gpt-realtime-2"
      assert broker.gateway == StubGateway
    end

    test "uses default Config when none provided" do
      broker = Broker.new("gpt-realtime-2", gateway: StubGateway)

      assert %Config{} = broker.config
    end

    test "accepts custom config" do
      config = Config.new(modalities: [:text])
      broker = Broker.new("gpt-realtime-2", gateway: StubGateway, config: config)

      assert broker.config.modalities == [:text]
    end

    test "uses ParallelToolRunner as default tool runner" do
      broker = Broker.new("gpt-realtime-2", gateway: StubGateway)

      assert broker.tool_runner == Mojentic.LLM.Tools.ParallelToolRunner
    end
  end

  describe "connect/1" do
    test "returns {:ok, session_pid} on success" do
      config = Config.new(modalities: [:text], turn_detection: :none)

      broker =
        Broker.new("gpt-realtime-2",
          gateway: StubGateway,
          config: config,
          transport_module: StubTransport
        )

      result = Broker.connect(broker)

      assert {:ok, session_pid} = result
      assert is_pid(session_pid)
      assert Process.alive?(session_pid)

      # Clean up
      Mojentic.Realtime.Session.close(session_pid)
    end
  end
end
