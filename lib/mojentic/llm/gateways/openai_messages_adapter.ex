defmodule Mojentic.LLM.Gateways.OpenAIMessagesAdapter do
  @moduledoc """
  Adapter for converting LLM messages to OpenAI format.

  This module handles the conversion of universal message format to
  OpenAI's API format, including multimodal content with images.
  """

  alias Mojentic.LLM.Message
  alias Mojentic.LLM.ToolCall

  require Logger

  @doc """
  Adapts LLM messages to OpenAI format.

  ## Parameters

    * `messages` - List of LLM messages to adapt

  ## Returns

    List of messages in OpenAI API format

  """
  @spec adapt_messages([Message.t()]) :: [map()]
  def adapt_messages(messages) do
    Enum.map(messages, &adapt_message/1)
  end

  @doc """
  Converts tool calls from OpenAI format to internal format.

  ## Parameters

    * `tool_calls` - List of tool calls in OpenAI format

  ## Returns

    List of ToolCall structs

  """
  @spec convert_tool_calls([map()]) :: [ToolCall.t()]
  def convert_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      args = parse_arguments(tc["function"]["arguments"])

      %ToolCall{
        id: tc["id"],
        name: tc["function"]["name"],
        arguments: args
      }
    end)
  end

  # Private functions

  defp adapt_message(%Message{role: :system, content: content}) do
    %{role: "system", content: content || ""}
  end

  defp adapt_message(%Message{role: :user, content: content, image_paths: image_paths})
       when is_list(image_paths) and image_paths != [] do
    content_parts = []

    # Add text content
    content_parts =
      if content && content != "" do
        [%{type: "text", text: content} | content_parts]
      else
        content_parts
      end

    # Add images
    content_parts =
      Enum.reduce(image_paths, content_parts, fn path, acc ->
        case encode_image(path) do
          {:ok, data_url} ->
            [%{type: "image_url", image_url: %{url: data_url}} | acc]

          {:error, reason} ->
            Logger.warning("Failed to encode image #{path}: #{inspect(reason)}")
            acc
        end
      end)

    %{role: "user", content: Enum.reverse(content_parts)}
  end

  defp adapt_message(%Message{role: :user, content: content}) do
    %{role: "user", content: content || ""}
  end

  defp adapt_message(%Message{role: :assistant, content: content, tool_calls: nil}) do
    %{role: "assistant", content: content || ""}
  end

  defp adapt_message(%Message{role: :assistant, content: content, tool_calls: tool_calls}) do
    formatted_calls =
      Enum.map(tool_calls, fn tc ->
        %{
          id: tc.id || "",
          type: "function",
          function: %{
            name: tc.name,
            arguments: Jason.encode!(tc.arguments)
          }
        }
      end)

    msg = %{role: "assistant", tool_calls: formatted_calls}

    if content do
      Map.put(msg, :content, content)
    else
      msg
    end
  end

  defp adapt_message(%Message{role: :tool, content: content, tool_calls: tool_calls}) do
    # Get tool_call_id from the first tool call if available
    tool_call_id =
      case tool_calls do
        [%ToolCall{id: id} | _] when not is_nil(id) -> id
        _ -> ""
      end

    %{
      role: "tool",
      content: content || "",
      tool_call_id: tool_call_id
    }
  end

  defp encode_image(file_path) do
    case File.read(file_path) do
      {:ok, bytes} ->
        base64_data = Base.encode64(bytes)
        image_type = get_image_type(file_path)
        {:ok, "data:image/#{image_type};base64,#{base64_data}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_image_type(file_path) do
    ext =
      file_path
      |> Path.extname()
      |> String.downcase()
      |> String.trim_leading(".")

    case ext do
      "jpg" -> "jpeg"
      "jpeg" -> "jpeg"
      "png" -> "png"
      "gif" -> "gif"
      "webp" -> "webp"
      _ -> "jpeg"
    end
  end

  defp parse_arguments(args_string) when is_binary(args_string) do
    case Jason.decode(args_string) do
      {:ok, args} when is_map(args) -> args
      _ -> %{}
    end
  end

  defp parse_arguments(_), do: %{}
end
