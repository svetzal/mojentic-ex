defmodule Mojentic.TestSupport.ContextWindowContract do
  @moduledoc false
  @external_resource "test/contracts/context_window_v1.json"
  @contract Jason.decode!(File.read!(@external_resource))

  def contract, do: @contract

  def result(%{"expected" => %{"error" => "invalid_response"}}),
    do: {:error, :invalid_response}

  def result(%{"expected" => %{"error" => ["http_error", status]}}),
    do: {:error, {:http_error, status}}

  def result(%{"expected" => %{"window" => window}}), do: {:ok, window(window)}

  def window(nil), do: nil

  def window(value) do
    fields = [
      max_context_tokens: "max_context_tokens",
      field: "field",
      model_num_ctx: "model_num_ctx"
    ]

    for {key, name} <- fields, Map.has_key?(value, name), into: %{}, do: {key, value[name]}
  end

  def response(row), do: http(row["status"], row["response"])

  def http(status, body),
    do:
      "HTTP/1.1 #{status} fixture\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
end
