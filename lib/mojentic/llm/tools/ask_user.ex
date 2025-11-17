defmodule Mojentic.LLM.Tools.AskUser do
  @moduledoc """
  Tool for asking the user a question and receiving their input.

  This tool allows the LLM to request help from the user when it needs
  additional information or doesn't know how to proceed. The user's response
  is returned as the tool result.

  ## Examples

      alias Mojentic.LLM.Tools.AskUser

      tool = AskUser.new()
      {:ok, result} = AskUser.run(tool, %{
        "user_request" => "What is your favorite color?"
      })
      # Prompts user for input:
      #
      #
      #
      # I NEED YOUR HELP!
      # What is your favorite color?
      # Your response: blue
      #
      # Returns: {:ok, "blue"}

  """

  @behaviour Mojentic.LLM.Tools.Tool

  defstruct []

  @doc """
  Creates a new AskUser tool instance.
  """
  def new do
    %__MODULE__{}
  end

  @impl true
  def run(%__MODULE__{}, arguments) do
    user_request = Map.get(arguments, "user_request", "")

    IO.puts("\n\n\nI NEED YOUR HELP!\n#{user_request}")
    IO.write("Your response: ")

    case IO.gets("") do
      :eof ->
        {:error, :user_input_eof}

      {:error, reason} ->
        {:error, reason}

      response when is_binary(response) ->
        {:ok, String.trim(response)}
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "ask_user",
        description:
          "If you do not know how to proceed, ask the user a question, or ask them for help or to do something for you.",
        parameters: %{
          type: "object",
          properties: %{
            user_request: %{
              type: "string",
              description:
                "The question you need the user to answer, or the task you need the user to do for you."
            }
          },
          required: ["user_request"]
        }
      }
    }
  end
end
