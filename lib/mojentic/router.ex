defmodule Mojentic.Router do
  @moduledoc """
  Routes events to agents based on event type.

  The Router maintains a mapping from event types (modules) to lists of agents
  that should receive those events. When an event is dispatched, the router
  determines which agents should process it.

  ## Usage

      router = Router.new()
      router = Router.add_route(router, QuestionEvent, fact_checker_agent)
      router = Router.add_route(router, QuestionEvent, answer_generator_agent)

      agents = Router.get_agents(router, %QuestionEvent{...})
      #=> [fact_checker_agent, answer_generator_agent]

  ## Examples

      # Create a router
      router = Router.new()

      # Add routes for different event types
      router = router
      |> Router.add_route(QuestionEvent, fact_checker)
      |> Router.add_route(QuestionEvent, answer_generator)
      |> Router.add_route(FactCheckEvent, aggregator)
      |> Router.add_route(AnswerEvent, aggregator)

      # Get agents for an event
      agents = Router.get_agents(router, question_event)

  """

  @type t :: %__MODULE__{
          routes: %{module() => [pid() | module()]}
        }

  defstruct routes: %{}

  @doc """
  Creates a new empty router.

  ## Examples

      iex> Router.new()
      %Router{routes: %{}}

  """
  def new do
    %__MODULE__{routes: %{}}
  end

  @doc """
  Adds a route mapping an event type to an agent.

  Multiple agents can be registered for the same event type.
  When an event of that type is dispatched, all registered agents
  will receive it.

  ## Parameters

  - `router` - The router to update
  - `event_type` - The event module to route
  - `agent` - The agent (pid or module) to receive events of this type

  ## Examples

      iex> router = Router.new()
      iex> router = Router.add_route(router, QuestionEvent, my_agent)
      iex> Router.get_agents(router, %QuestionEvent{})
      [my_agent]

  """
  def add_route(%__MODULE__{routes: routes} = router, event_type, agent) do
    agents = Map.get(routes, event_type, [])
    routes = Map.put(routes, event_type, agents ++ [agent])
    %{router | routes: routes}
  end

  @doc """
  Gets all agents registered to handle a specific event.

  ## Parameters

  - `router` - The router to query
  - `event` - The event struct to find handlers for

  ## Returns

  A list of agents (pids or modules) that handle this event type.
  Returns an empty list if no agents are registered.

  ## Examples

      iex> router = Router.new()
      iex> router = Router.add_route(router, QuestionEvent, agent1)
      iex> router = Router.add_route(router, QuestionEvent, agent2)
      iex> Router.get_agents(router, %QuestionEvent{})
      [agent1, agent2]

  """
  def get_agents(%__MODULE__{routes: routes}, %{__struct__: event_type}) do
    Map.get(routes, event_type, [])
  end
end
