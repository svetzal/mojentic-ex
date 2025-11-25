defmodule Mojentic.Examples.React.OutputAgent do
  @moduledoc """
  Output agent for the ReAct pattern.

  This simple agent logs all events for observability and debugging.
  """

  require Logger

  @doc """
  Receives and logs any event.

  This agent acts as an observer, logging event information without
  producing new events.

  ## Parameters

  - `_broker`: LLM broker (unused by this agent)
  - `event`: Any event in the ReAct loop

  ## Returns

  - `{:ok, []}` - Never produces new events
  """
  def receive_event_async(_broker, event) do
    Logger.debug("OutputAgent received: #{inspect(event.__struct__)}")
    {:ok, []}
  end
end
