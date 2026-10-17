defmodule Mojentic.TestSupport.FirstTokenContract do
  @moduledoc false
  @external_resource "test/contracts/stream_first_token_v1.json"
  @contract Jason.decode!(File.read!(@external_resource))
  def contract, do: @contract

  def frame(:ollama, delta), do: Jason.encode!(%{message: delta, done: false}) <> "\n"

  def frame(_provider, delta) do
    delta =
      case Map.pop(delta, "thinking") do
        {nil, delta} -> delta
        {thinking, delta} -> Map.put(delta, "reasoning_content", thinking)
      end

    "data: " <> Jason.encode!(%{choices: [%{delta: delta}]}) <> "\n\n"
  end

  def terminal(:ollama),
    do:
      Jason.encode!(%{
        message: %{},
        done: true,
        done_reason: "stop",
        model: "fixture-model",
        total_duration: 900,
        prompt_eval_duration: 200
      }) <> "\n"

  def terminal(_provider),
    do:
      "data: " <>
        Jason.encode!(%{
          choices: [%{delta: %{}, finish_reason: "stop"}],
          model: "fixture-model",
          usage: %{time_to_first_token: 0.7, total_tokens: 5}
        }) <> "\n\ndata: [DONE]\n\n"

  def prefix(:omlx),
    do:
      ~s(data: {"model":"keepalive","choices":[{"delta":{"content":"ghost"}}]}\n\n) <>
        frame(:omlx, %{"content" => ""})

  def prefix(provider), do: frame(provider, %{}) <> frame(provider, %{"content" => ""})

  def headers,
    do: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"

  def chunk(data), do: Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"
end
