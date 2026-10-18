defmodule Mojentic.LLM.OfflineTransportTest.Adapter do
  @moduledoc false
  def run(request), do: request.private.test_adapter.(request)
end

defmodule Mojentic.LLM.OfflineTransportTest do
  use ExUnit.Case, async: false

  import Mox

  alias Mojentic.LLM.{CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.OMLX

  test "prepared dispatch precedes observation and rejected capture retains timing without delivery" do
    owner = self()
    clock = start_supervised!({Agent, fn -> 10 end})

    previous =
      Map.new([:http_client, :monotonic_clock], &{&1, Application.get_env(:mojentic, &1)})

    previous_req = Req.default_options()
    set_mox_global()
    stub(Mojentic.MonotonicClockMock, :now, fn -> Agent.get(clock, & &1) end)
    Application.put_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
    Application.put_env(:mojentic, :monotonic_clock, Mojentic.MonotonicClockMock)

    on_exit(fn ->
      Req.default_options(previous_req)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:mojentic, key)
        {key, value} -> Application.put_env(:mojentic, key, value)
      end)
    end)

    adapter = fn request ->
      send(owner, {:stage, :dispatch})
      assert Req.Request.get_header(request, "content-type") == ["application/json"]
      assert request.options.retry == false
      send(owner, {:transport_request, request.method, request.url.path, request.body})
      Agent.update(clock, fn _ -> 125 end)
      ref = make_ref()
      send(self(), {ref, :frame})

      body = %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: fn ^ref, {^ref, :frame} ->
          {:ok, [data: "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n\n"]}
        end,
        cancel_fun: fn ^ref -> send(owner, :transport_closed) end
      }

      {request, Req.Response.new(status: 200, body: body)}
    end

    Req.default_options(
      adapter: __MODULE__.Adapter,
      plugins: [
        fn request ->
          request
          |> Req.Request.put_private(:test_adapter, adapter)
          |> Req.Request.append_request_steps(
            test_preparation: fn prepared ->
              Agent.update(clock, fn _ -> 100 end)
              send(owner, {:stage, :prepared})
              prepared
            end
          )
        end
      ]
    )

    config =
      CompletionConfig.new(
        recovery: [
          max_attempts: 2,
          trace_observer: fn
            %{type: :request} ->
              Agent.update(clock, fn _ -> 80 end)
              send(owner, {:stage, :capture})
              :ok

            %{type: :response_data} ->
              Agent.update(clock, fn _ -> 180 end)
              {:error, :rejected}

            _ ->
              :ok
          end
        ]
      )

    assert [{:error, %CompletionError{} = error}] =
             OMLX.complete_stream_events("local", [Message.user("hello")], config)
             |> Enum.to_list()

    assert error.reason == :capture_failed
    assert error.progress.observed.content
    refute error.progress.delivered.content

    assert error.metadata == %{
             time_to_first_token_ms: 25,
             first_token_kind: :content,
             request_duration_ms: 80
           }

    assert_receive {:transport_request, :post, "/v1/chat/completions", body}

    assert Jason.decode!(body) == %{
             "model" => "local",
             "messages" => [%{"role" => "user", "content" => "hello"}],
             "stream" => true,
             "stream_options" => %{"include_usage" => true}
           }

    assert stages() == [:capture, :prepared, :dispatch]
    assert_receive :transport_closed
    refute_received {:transport_request, _, _, _}
  end

  defp stages do
    receive do
      {:stage, stage} -> [stage | stages()]
    after
      0 -> []
    end
  end
end
