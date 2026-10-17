defmodule Mojentic.LLM.ModelContextWindow do
  @moduledoc """
  Provider-advertised context capacity and its field provenance.

  Discovery is read-only. A window is distinct from request configuration and
  from the server's currently loaded context size.
  """

  @type t :: %{
          required(:max_context_tokens) => pos_integer(),
          required(:field) => String.t(),
          optional(:model_num_ctx) => pos_integer()
        }

  @doc false
  def decode(body, parser) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> parser.(decoded)
      _ -> {:error, :invalid_response}
    end
  end

  @doc false
  def omlx(%{"data" => models}, model) when is_list(models) do
    if Enum.all?(models, &(is_map(&1) and is_binary(Map.get(&1, "id")))) do
      case Enum.find(models, &(&1["id"] == model)) do
        nil -> {:ok, nil}
        entry -> advertised(entry, "max_model_len", "max_model_len")
      end
    else
      {:error, :invalid_response}
    end
  end

  def omlx(_, _), do: {:error, :invalid_response}

  @doc false
  def ollama(body) do
    with {:ok, window} <- architecture_window(Map.get(body, "model_info")),
         {:ok, num_ctx} <- model_num_ctx(Map.get(body, "parameters")) do
      case {window, num_ctx} do
        {nil, _} -> {:ok, nil}
        {window, nil} -> {:ok, window}
        {window, num_ctx} -> {:ok, Map.put(window, :model_num_ctx, num_ctx)}
      end
    end
  end

  defp architecture_window(nil), do: {:ok, nil}

  defp architecture_window(info) when is_map(info) do
    case Enum.find(Enum.sort(info), fn {key, _} -> String.ends_with?(key, ".context_length") end) do
      nil -> {:ok, nil}
      {key, _} -> advertised(info, key, "model_info." <> key)
    end
  end

  defp architecture_window(_), do: {:error, :invalid_response}

  defp advertised(map, key, field) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, tokens} when is_integer(tokens) and tokens > 0 ->
        {:ok, %{max_context_tokens: tokens, field: field}}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp model_num_ctx(nil), do: {:ok, nil}

  defp model_num_ctx(parameters) when is_binary(parameters) do
    parameters
    |> String.split("\n")
    |> Enum.map(&String.split/1)
    |> Enum.find_value({:ok, nil}, &parse_num_ctx/1)
  end

  defp model_num_ctx(_), do: {:error, :invalid_response}

  defp parse_num_ctx(["num_ctx", value]) do
    case Integer.parse(value) do
      {tokens, ""} when tokens > 0 -> {:ok, tokens}
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_num_ctx(["num_ctx" | _]), do: {:error, :invalid_response}
  defp parse_num_ctx(_), do: nil
end
