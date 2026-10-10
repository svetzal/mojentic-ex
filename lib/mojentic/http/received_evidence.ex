defmodule Mojentic.HTTP.ReceivedEvidence do
  @moduledoc false

  def new(mode),
    do: %{status: nil, headers: [], body: "", mode: mode, cause: nil, complete: false}

  def observe({:headers, status, headers}, evidence),
    do: %{evidence | status: status, headers: headers}

  def observe({kind, chunk}, evidence) when kind in [:data, :http_data],
    do: %{evidence | body: evidence.body <> chunk}

  def observe({:error, cause}, evidence), do: %{evidence | cause: cause}

  def complete(evidence), do: %{evidence | complete: true}

  def progress(evidence) do
    empty = %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

    {observed, _tools} =
      Enum.reduce(messages(evidence), {empty, %{}}, fn {message, terminal}, {observed, tools} ->
        calls = Map.get(message, "tool_calls", [])
        calls = if is_list(calls), do: calls, else: []

        tools = Enum.reduce(Enum.with_index(calls), tools, &assemble/2)

        observed = %{
          observed
          | content: observed.content or present?(message["content"]),
            reasoning:
              observed.reasoning or present?(message["thinking"] || message["reasoning_content"]),
            tool_fragments:
              observed.tool_fragments + if(evidence.mode != :ordinary, do: length(calls), else: 0),
            completed_tool_calls:
              observed.completed_tool_calls + completed_tools(evidence, tools, terminal)
        }

        {observed, tools}
      end)

    %{
      headers_received: evidence.status != nil,
      raw_bytes: byte_size(evidence.body),
      observed: observed,
      delivered: empty
    }
  end

  defp completed_tools(%{mode: {_provider, :events}}, _tools, _terminal), do: 0
  defp completed_tools(%{mode: {_provider, :legacy}}, _tools, false), do: 0

  defp completed_tools(_evidence, tools, _terminal),
    do: Enum.count(tools, fn {_, tool} -> complete?(tool) end)

  defp messages(%{mode: :ordinary, body: body}),
    do: Enum.map(decode_message(body), fn {message, _terminal} -> {message, true} end)

  defp messages(%{mode: {:ollama, _mode}, complete: true, body: body}) do
    body |> String.split("\n") |> Enum.flat_map(&decode_line/1)
  end

  defp messages(%{body: body}) do
    body
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.flat_map(fn line ->
      decode_line(line)
    end)
  end

  defp decode_line(line) do
    line |> String.trim() |> String.replace_prefix("data: ", "") |> decode_message()
  rescue
    _ -> []
  end

  defp decode_message(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message} = frame} when is_map(message) ->
        [{message, frame["done"] == true}]

      {:ok, %{"choices" => [%{"message" => message} | _]}} when is_map(message) ->
        [{message, true}]

      {:ok, %{"choices" => [%{"delta" => message} = choice | _]}} when is_map(message) ->
        [{message, choice["finish_reason"] in ["stop", "tool_calls"]}]

      _ ->
        []
    end
  end

  defp assemble({call, index}, tools) when is_map(call) do
    key = call["index"] || index
    old = Map.get(tools, key, %{name: nil, arguments: ""})
    function = call["function"]
    function = if is_map(function), do: function, else: %{}
    arguments = function["arguments"] || ""

    arguments =
      case arguments do
        map when is_map(map) -> Jason.encode!(map)
        text when is_binary(text) -> old.arguments <> text
        _ -> old.arguments
      end

    Map.put(tools, key, %{name: function["name"] || old.name, arguments: arguments})
  end

  defp assemble(_, tools), do: tools

  defp complete?(%{name: name, arguments: arguments}) do
    present?(name) and match?({:ok, map} when is_map(map), Jason.decode(arguments))
  end

  defp present?(text), do: is_binary(text) and byte_size(text) > 0
end
