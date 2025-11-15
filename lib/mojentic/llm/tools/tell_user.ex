defmodule Mojentic.LLM.Tools.TellUser do
  @moduledoc """
  Tool for displaying messages to the user without expecting a response.

  This tool allows the LLM to send important intermediate information to the user
  as it works on completing their request. It's useful for providing status updates,
  progress information, or other important messages during long-running operations.

  ## Examples

      alias Mojentic.LLM.Tools.TellUser

      tool = TellUser.new()
      {:ok, result} = TellUser.run(tool, %{"message" => "Processing your request..."})
      # Prints to stdout:
      #
      #
      #
      # MESSAGE FROM ASSISTANT:
      # Processing your request...
      #
      # Returns: {:ok, "Message delivered to user."}

  """

  @behaviour Mojentic.LLM.Tools.Tool

  defstruct []

  @doc """
  Creates a new TellUser tool instance.
  """
  def new do
    %__MODULE__{}
  end

  @impl true
  def run(%__MODULE__{}, arguments) do
    message = Map.get(arguments, "message", "")

    IO.puts("\n\n\nMESSAGE FROM ASSISTANT:\n#{message}")

    {:ok, "Message delivered to user."}
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "tell_user",
        description:
          "Display a message to the user without expecting a response. Use this to send important intermediate information to the user as you work on completing their request.",
        parameters: %{
          type: "object",
          properties: %{
            message: %{
              type: "string",
              description: "The important message you want to display to the user."
            }
          },
          required: ["message"]
        }
      }
    }
  end
end
