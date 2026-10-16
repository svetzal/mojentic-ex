defmodule Mojentic.LLM.NoHookWireTest do
  use ExUnit.Case, async: false

  alias Mojentic.LLM.{CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.Ollama
  alias Mojentic.TestSupport.ScriptedCompletionServer

  @tag :no_hook
  @tag :no_hook_proof
  test "local event stream without admission never resends an ambiguous failure" do
    client = Application.fetch_env!(:mojentic, :http_client)
    host = System.get_env("OLLAMA_HOST")
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)

    on_exit(fn ->
      Application.put_env(:mojentic, :http_client, client)
      if host, do: System.put_env("OLLAMA_HOST", host), else: System.delete_env("OLLAMA_HOST")
    end)

    body = "ambiguous-failure"

    response =
      "HTTP/1.1 503 Unavailable\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"

    server = start_supervised!({ScriptedCompletionServer, {self(), [response, response]}})
    assert_receive {:server_port, port}
    System.put_env("OLLAMA_HOST", "http://127.0.0.1:#{port}")
    owner = self()

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          base_delay: 0,
          sleeper: fn _ -> :ok end,
          observer: &send(owner, {:lifecycle, &1})
        ]
      )

    assert [{:error, %CompletionError{} = error}] =
             Ollama.complete_stream_events(
               "fixture-model",
               [Message.user("unchanged-input")],
               config
             )
             |> Enum.to_list()

    assert_receive {:wire_request, wire}
    [_, encoded] = String.split(wire, "\r\n\r\n", parts: 2)

    assert Jason.decode!(encoded) == %{
             "model" => "fixture-model",
             "messages" => [
               %{"role" => "user", "content" => "unchanged-input"}
             ],
             "stream" => true,
             "options" => %{"temperature" => 1.0, "num_ctx" => 32_768, "num_predict" => 16_384}
           }

    assert GenServer.call(server, :requests) == [wire]
    refute_receive {:wire_request, _}
    assert error.resend_permission == :admission_required
    assert error.acceptance == :unknown
    assert error.retry_eligible
    assert error.http_status == 503
    assert [%{wire_attempt: 1, attempt_id: attempt, logical_request_id: logical}] = error.history
    assert attempt == error.attempt_id
    assert logical == error.logical_request_id

    events =
      for _ <- 1..4 do
        assert_receive {:lifecycle, event}
        event
      end

    assert Enum.map(events, & &1.type) == [
             :attempt_started,
             :attempt_failed,
             :admission_required,
             :exhausted
           ]
  end
end
