defmodule Mojentic.LLM.Gateways.OpenAITest do
  use ExUnit.Case, async: true

  import Mox

  alias Mojentic.LLM.CompletionConfig
  alias Mojentic.LLM.Gateways.OpenAI
  alias Mojentic.LLM.Message

  setup :verify_on_exit!

  @schema %{"type" => "object", "properties" => %{"answer" => %{"type" => "string"}}}

  @formats [
    {nil, nil},
    {%{type: :text}, %{"type" => "text"}},
    {%{type: :json_object}, %{"type" => "json_object"}},
    {%{type: :json_object, schema: nil}, %{"type" => "json_object"}},
    {%{type: :json_object, schema: @schema},
     %{"type" => "json_schema", "json_schema" => %{"name" => "response", "schema" => @schema}}}
  ]

  @completion Jason.encode!(%{
                "model" => "gpt-4o-2024-08-06",
                "choices" => [
                  %{"message" => %{"content" => "{}"}, "finish_reason" => "stop"}
                ],
                "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 2}
              })

  describe "response format forwarding" do
    test "non-streaming requests carry the configured format and omit it when absent" do
      for {format, expected} <- @formats do
        expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, _opts ->
          send(self(), {:body, Jason.decode!(body)})
          {:ok, %{status_code: 200, body: @completion}}
        end)

        assert {:ok, _} = OpenAI.complete("gpt-4o", [Message.user("hi")], nil, config(format))
        assert_received {:body, body}
        assert_format(body, expected)
      end
    end

    test "legacy streaming requests carry the configured format and omit it when absent" do
      for {format, expected} <- @formats do
        expect_stream_body()

        "gpt-4o"
        |> OpenAI.complete_stream([Message.user("hi")], nil, config(format))
        |> Enum.to_list()

        assert_received {:body, body}
        assert_format(body, expected)
      end
    end

    test "single-turn event requests carry the configured format and request usage" do
      for {format, expected} <- @formats do
        expect_stream_body()

        "gpt-4o"
        |> OpenAI.complete_stream_events([Message.user("hi")], config(format))
        |> Enum.to_list()

        assert_received {:body, body}
        assert_format(body, expected)
        assert body["stream_options"] == %{"include_usage" => true}
      end
    end
  end

  defp config(format), do: CompletionConfig.new(response_format: format)

  defp expect_stream_body do
    expect(Mojentic.HTTPMock, :post_stream, fn _url, body, _headers, _opts ->
      send(self(), {:body, Jason.decode!(body)})
      {:ok, []}
    end)
  end

  defp assert_format(body, nil), do: refute(Map.has_key?(body, "response_format"))
  defp assert_format(body, expected), do: assert(body["response_format"] == expected)
end
