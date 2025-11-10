defmodule Mojentic.LLM.Message do
  @moduledoc """
  Represents a message in an LLM conversation.

  Messages can have different roles (system, user, assistant, tool) and
  can contain text content, tool calls, and image references.

  ## Examples

      iex> Message.user("Hello, world!")
      %Message{role: :user, content: "Hello, world!"}

      iex> Message.system("You are a helpful assistant.")
      %Message{role: :system, content: "You are a helpful assistant."}

  """

  alias Mojentic.LLM.ToolCall

  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t() | nil,
          tool_calls: [ToolCall.t()] | nil,
          image_paths: [String.t()] | nil
        }

  @enforce_keys [:role]
  defstruct [
    :role,
    :content,
    :tool_calls,
    :image_paths
  ]

  @doc """
  Creates a user message.

  ## Examples

      iex> Message.user("Hello!")
      %Message{role: :user, content: "Hello!"}

  """
  def user(content) when is_binary(content) do
    %__MODULE__{role: :user, content: content}
  end

  @doc """
  Creates a system message.

  ## Examples

      iex> Message.system("You are helpful.")
      %Message{role: :system, content: "You are helpful."}

  """
  def system(content) when is_binary(content) do
    %__MODULE__{role: :system, content: content}
  end

  @doc """
  Creates an assistant message.

  ## Examples

      iex> Message.assistant("I understand.")
      %Message{role: :assistant, content: "I understand."}

  """
  def assistant(content) when is_binary(content) do
    %__MODULE__{role: :assistant, content: content}
  end

  @doc """
  Adds image paths to a message.

  ## Examples

      iex> Message.user("Describe this image") |> Message.with_images(["/path/to/image.jpg"])
      %Message{role: :user, content: "Describe this image", image_paths: ["/path/to/image.jpg"]}

  """
  def with_images(%__MODULE__{} = message, paths) when is_list(paths) do
    %{message | image_paths: paths}
  end
end
