defmodule Mojentic.RouterTest do
  use ExUnit.Case, async: true

  alias Mojentic.{Event, Router}

  defmodule EventA do
    use Event
    defstruct [:source, :correlation_id]
  end

  defmodule EventB do
    use Event
    defstruct [:source, :correlation_id]
  end

  defmodule AgentOne do
  end

  defmodule AgentTwo do
  end

  describe "Router.new/0" do
    test "creates empty router" do
      router = Router.new()

      assert %Router{routes: routes} = router
      assert routes == %{}
    end
  end

  describe "Router.add_route/3" do
    test "adds single route" do
      router = Router.new()
      router = Router.add_route(router, EventA, AgentOne)

      event = %EventA{source: __MODULE__}
      agents = Router.get_agents(router, event)

      assert agents == [AgentOne]
    end

    test "adds multiple routes for same event type" do
      router = Router.new()
      router = Router.add_route(router, EventA, AgentOne)
      router = Router.add_route(router, EventA, AgentTwo)

      event = %EventA{source: __MODULE__}
      agents = Router.get_agents(router, event)

      assert agents == [AgentOne, AgentTwo]
    end

    test "adds routes for different event types" do
      router = Router.new()
      router = Router.add_route(router, EventA, AgentOne)
      router = Router.add_route(router, EventB, AgentTwo)

      event_a = %EventA{source: __MODULE__}
      event_b = %EventB{source: __MODULE__}

      assert Router.get_agents(router, event_a) == [AgentOne]
      assert Router.get_agents(router, event_b) == [AgentTwo]
    end

    test "is pipeable" do
      router =
        Router.new()
        |> Router.add_route(EventA, AgentOne)
        |> Router.add_route(EventA, AgentTwo)
        |> Router.add_route(EventB, AgentOne)

      event_a = %EventA{source: __MODULE__}
      event_b = %EventB{source: __MODULE__}

      assert Router.get_agents(router, event_a) == [AgentOne, AgentTwo]
      assert Router.get_agents(router, event_b) == [AgentOne]
    end
  end

  describe "Router.get_agents/2" do
    test "returns empty list for unregistered event type" do
      router = Router.new()
      event = %EventA{source: __MODULE__}

      assert Router.get_agents(router, event) == []
    end

    test "returns agents in registration order" do
      router = Router.new()
      router = Router.add_route(router, EventA, AgentOne)
      router = Router.add_route(router, EventA, AgentTwo)
      router = Router.add_route(router, EventA, AgentOne)

      event = %EventA{source: __MODULE__}
      agents = Router.get_agents(router, event)

      assert agents == [AgentOne, AgentTwo, AgentOne]
    end

    test "handles pids as agents" do
      router = Router.new()
      pid = self()
      router = Router.add_route(router, EventA, pid)

      event = %EventA{source: __MODULE__}
      agents = Router.get_agents(router, event)

      assert agents == [pid]
    end

    test "matches on event struct type" do
      router = Router.new()
      router = Router.add_route(router, EventA, AgentOne)

      event_a = %EventA{source: __MODULE__, correlation_id: "test-123"}
      event_b = %EventB{source: __MODULE__, correlation_id: "test-123"}

      assert Router.get_agents(router, event_a) == [AgentOne]
      assert Router.get_agents(router, event_b) == []
    end
  end
end
