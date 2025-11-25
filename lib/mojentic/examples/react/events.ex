defmodule Mojentic.Examples.React.Events do
  @moduledoc """
  Event definitions for the ReAct pattern.

  This module defines all event types used to coordinate the ReAct loop,
  including thinking, decisioning, tool calls, completion, and failure events.
  """

  alias Mojentic.Examples.React.Models.{CurrentContext, NextAction}

  defmodule InvokeThinking do
    @moduledoc """
    Event to trigger the thinking/planning phase.

    This event initiates the planning process where the agent creates
    or refines a plan for answering the user's query.
    """
    use Mojentic.Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            context: CurrentContext.t()
          }

    @enforce_keys [:source, :context]
    defstruct [:source, :correlation_id, :context]
  end

  defmodule InvokeDecisioning do
    @moduledoc """
    Event to trigger the decision-making phase.

    This event initiates the decision process where the agent evaluates
    the current plan and history to decide on the next action.
    """
    use Mojentic.Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            context: CurrentContext.t()
          }

    @enforce_keys [:source, :context]
    defstruct [:source, :correlation_id, :context]
  end

  defmodule InvokeToolCall do
    @moduledoc """
    Event to trigger a tool invocation.

    This event carries the information needed to execute a specific tool
    with given arguments, along with the reasoning behind the decision.
    """
    use Mojentic.Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            context: CurrentContext.t(),
            thought: String.t(),
            action: NextAction.t(),
            tool: module(),
            tool_arguments: map()
          }

    @enforce_keys [:source, :context, :thought, :action, :tool]
    defstruct [:source, :correlation_id, :context, :thought, :action, :tool, tool_arguments: %{}]
  end

  defmodule FinishAndSummarize do
    @moduledoc """
    Event to trigger the completion and summarization phase.

    This event indicates that the agent has gathered sufficient information
    to answer the user's query and should generate a final response.
    """
    use Mojentic.Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            context: CurrentContext.t(),
            thought: String.t()
          }

    @enforce_keys [:source, :context, :thought]
    defstruct [:source, :correlation_id, :context, :thought]
  end

  defmodule FailureOccurred do
    @moduledoc """
    Event to signal a failure in the ReAct loop.

    This event captures errors or unrecoverable situations that prevent
    the agent from continuing to process the user's query.
    """
    use Mojentic.Event

    @type t :: %__MODULE__{
            source: module(),
            correlation_id: String.t() | nil,
            context: CurrentContext.t(),
            reason: String.t()
          }

    @enforce_keys [:source, :context, :reason]
    defstruct [:source, :correlation_id, :context, :reason]
  end
end
