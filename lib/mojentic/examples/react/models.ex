defmodule Mojentic.Examples.React.Models do
  @moduledoc """
  Data models for the ReAct pattern.

  This module defines the core data structures used throughout the ReAct
  implementation, including actions, plans, observations, and context.
  """

  defmodule NextAction do
    @moduledoc """
    Enumeration of possible next actions in the ReAct loop.
    """

    @type t :: :plan | :act | :finish

    @doc """
    Parses a string into a NextAction value.
    """
    def parse("PLAN"), do: {:ok, :plan}
    def parse("ACT"), do: {:ok, :act}
    def parse("FINISH"), do: {:ok, :finish}
    def parse(_), do: {:error, :invalid_action}

    @doc """
    Converts a NextAction to a string.
    """
    def to_string(:plan), do: "PLAN"
    def to_string(:act), do: "ACT"
    def to_string(:finish), do: "FINISH"
  end

  defmodule ThoughtActionObservation do
    @moduledoc """
    A single step in the ReAct loop capturing thought, action, and observation.

    This model represents one iteration of the ReAct pattern where the agent:
    1. Thinks about what to do
    2. Takes an action
    3. Observes the result
    """

    @type t :: %__MODULE__{
            thought: String.t(),
            action: String.t(),
            observation: String.t()
          }

    @enforce_keys [:thought, :action, :observation]
    defstruct [:thought, :action, :observation]

    @doc """
    Creates a new ThoughtActionObservation.
    """
    def new(thought, action, observation) do
      %__MODULE__{
        thought: thought,
        action: action,
        observation: observation
      }
    end
  end

  defmodule Plan do
    @moduledoc """
    A structured plan for solving a user query.

    Contains a list of steps that outline how to approach answering the query.
    """

    @type t :: %__MODULE__{
            steps: [String.t()]
          }

    defstruct steps: []

    @doc """
    Creates a new Plan with the given steps.
    """
    def new(steps \\ []) do
      %__MODULE__{steps: steps}
    end
  end

  defmodule CurrentContext do
    @moduledoc """
    The complete context for a ReAct session.

    This model tracks everything needed to maintain state throughout the
    reasoning and acting loop, including the user's query, the plan,
    the history of actions, and the iteration count.
    """

    @type t :: %__MODULE__{
            user_query: String.t(),
            plan: Plan.t(),
            history: [ThoughtActionObservation.t()],
            iteration: non_neg_integer()
          }

    @enforce_keys [:user_query]
    defstruct [
      :user_query,
      plan: %Plan{},
      history: [],
      iteration: 0
    ]

    @doc """
    Creates a new CurrentContext with the given user query.
    """
    def new(user_query, opts \\ []) do
      %__MODULE__{
        user_query: user_query,
        plan: Keyword.get(opts, :plan, %Plan{}),
        history: Keyword.get(opts, :history, []),
        iteration: Keyword.get(opts, :iteration, 0)
      }
    end
  end
end
