defmodule Mojentic.LLM.Gateways.OpenAILegacyStream do
  @moduledoc false

  # OpenAI-compatible server-sent events for the legacy `complete_stream/4`
  # API. Yields `{:content, text}` as content deltas arrive and
  # `{:tool_calls, [ToolCall.t()]}` once a tool call is complete, either at a
  # `tool_calls` finish reason, at `data: [DONE]`, or at the end of the body.
  # A transport failure yields `{:error, reason}` and ends the stream. Halting
  # enumeration closes the request.

  alias Mojentic.LLM.ToolCall

  require Logger

  @doc """
  Streams one response. `start` opens the request and returns
  `{:ok, body}`, where `body` enumerates `{:data, chunk}` and
  `{:error, reason}`, or `{:error, reason}`.
  """
  @spec stream((-> {:ok, Enumerable.t()} | {:error, term()})) :: Enumerable.t()
  def stream(start, opts \\ []) do
    Stream.resource(
      fn -> open(start) end,
      &process_stream_chunk(&1, Keyword.get(opts, :native_reasoning, false)),
      &cleanup_stream/1
    )
  end

  defp open(start) do
    case start.() do
      {:ok, stream} ->
        {:stream, stream_continuation(stream), "", %{}, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_stream_chunk(:halt, _reasoning?), do: {:halt, :halt}
  defp process_stream_chunk({:error, _reason} = error, _reasoning?), do: {[error], :halt}

  defp process_stream_chunk({:stream, stream, buffer, tool_calls_acc, evidence}, reasoning?) do
    case stream.({:cont, nil}) do
      {:suspended, {:data, chunk}, rest} ->
        parse_sse_chunks(chunk, buffer, tool_calls_acc, rest, reasoning?, evidence)

      {:suspended, {:error, _reason} = error, rest} ->
        rest.({:halt, nil})
        {[error], :halt}

      {done, _} when done in [:done, :halted] ->
        handle_stream_end(tool_calls_acc, evidence)
    end
  end

  defp handle_stream_end(tool_calls_acc, evidence) do
    result =
      if map_size(tool_calls_acc) > 0 do
        [{:tool_calls, build_complete_tool_calls(tool_calls_acc)}]
      else
        []
      end

    {result ++ [{:completed, evidence}], :halt}
  end

  defp stream_continuation(stream),
    do: &Enumerable.reduce(stream, &1, fn element, _ -> {:suspend, element} end)

  defp cleanup_stream({:stream, continuation, _, _, _}), do: continuation.({:halt, nil})
  defp cleanup_stream(:halt), do: :ok
  defp cleanup_stream({:error, _}), do: :ok
  defp cleanup_stream(_), do: :ok

  # Parse SSE chunks from OpenAI streaming response
  defp parse_sse_chunks(chunk, buffer, tool_calls_acc, rest_stream, reasoning?, evidence) do
    new_buffer = buffer <> chunk

    # Split on double newlines (SSE format)
    lines = String.split(new_buffer, "\n", trim: false)

    # Process complete lines
    {complete_lines, remaining_buffer} =
      if String.ends_with?(new_buffer, "\n") do
        {Enum.filter(lines, &(&1 != "")), ""}
      else
        case Enum.split(lines, -1) do
          {complete, [incomplete]} -> {Enum.filter(complete, &(&1 != "")), incomplete}
          {complete, []} -> {Enum.filter(complete, &(&1 != "")), ""}
        end
      end

    # Process each complete line
    {results, new_tool_calls_acc, evidence} =
      Enum.reduce_while(complete_lines, {[], tool_calls_acc, evidence}, fn line,
                                                                           {acc_results,
                                                                            acc_tools,
                                                                            evidence} ->
        if String.starts_with?(line, "data: ") do
          data = String.replace_prefix(line, "data: ", "")

          if data == "[DONE]" do
            tools =
              if map_size(acc_tools) > 0,
                do: [{:tool_calls, build_complete_tool_calls(acc_tools)}],
                else: []

            {:halt, {[{:completed, evidence} | tools ++ acc_results], %{}, evidence}}
          else
            case Jason.decode(data) do
              {:ok, json} ->
                {results, tools} = parse_streaming_json(json, acc_results, acc_tools, reasoning?)

                evidence =
                  Map.merge(
                    evidence,
                    Map.new(
                      [
                        {:usage, json["usage"]},
                        {:provider_model, json["model"]},
                        {:finish_reason, get_in(json, ["choices", Access.at(0), "finish_reason"])}
                      ]
                      |> Enum.reject(fn {_, value} -> is_nil(value) end)
                    )
                  )

                {:cont, {results, tools, evidence}}

              {:error, _} ->
                Logger.warning("Failed to parse SSE chunk: #{data}")
                {:cont, {acc_results, acc_tools, evidence}}
            end
          end
        else
          {:cont, {acc_results, acc_tools, evidence}}
        end
      end)

    {Enum.reverse(results),
     {:stream, rest_stream, remaining_buffer, new_tool_calls_acc, evidence}}
  end

  defp add_reasoning(results, true, text) when is_binary(text) and text != "",
    do: [{:thinking, text} | results]

  defp add_reasoning(results, _reasoning?, _text), do: results

  defp parse_streaming_json(json, acc_results, acc_tools, reasoning?) do
    case json do
      %{"choices" => [%{"delta" => delta} = choice | _]} ->
        # OpenAI-compatible servers may omit a null finish_reason.
        finish_reason = choice["finish_reason"]

        acc_results = add_reasoning(acc_results, reasoning?, delta["reasoning_content"])

        # Handle content
        acc_results =
          case Map.get(delta, "content") do
            nil -> acc_results
            "" -> acc_results
            content -> [{:content, content} | acc_results]
          end

        # Accumulate tool calls
        acc_tools =
          case Map.get(delta, "tool_calls") do
            nil ->
              acc_tools

            tool_calls ->
              Enum.reduce(tool_calls, acc_tools, fn tc, tools ->
                index = tc["index"]

                current =
                  Map.get(tools, index, %{
                    id: nil,
                    name: nil,
                    arguments: ""
                  })

                current =
                  if tc["id"] do
                    Map.put(current, :id, tc["id"])
                  else
                    current
                  end

                current =
                  case get_in(tc, ["function", "name"]) do
                    nil -> current
                    name -> Map.put(current, :name, name)
                  end

                current =
                  case get_in(tc, ["function", "arguments"]) do
                    nil -> current
                    args -> Map.put(current, :arguments, current.arguments <> args)
                  end

                Map.put(tools, index, current)
              end)
          end

        # Check if we need to emit tool calls
        if finish_reason == "tool_calls" && map_size(acc_tools) > 0 do
          {[{:tool_calls, build_complete_tool_calls(acc_tools)} | acc_results], %{}}
        else
          {acc_results, acc_tools}
        end

      _ ->
        {acc_results, acc_tools}
    end
  end

  defp build_complete_tool_calls(tool_calls_acc) do
    tool_calls_acc
    |> Enum.sort_by(fn {index, _} -> index end)
    |> Enum.map(fn {_index, tc} ->
      args =
        case Jason.decode(tc.arguments) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %ToolCall{
        id: tc.id,
        name: tc.name,
        arguments: args
      }
    end)
  end
end
