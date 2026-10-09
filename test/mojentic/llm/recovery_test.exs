defmodule Mojentic.LLM.RecoveryTest do
  use ExUnit.Case, async: true
  import Mox
  import ExUnit.CaptureLog
  alias Mojentic.LLM.{Broker, ChatSession, CompletionConfig, CompletionError, Message}
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}

  alias Mojentic.TestSupport.{CountingTool, DecodingEvidence}

  setup :verify_on_exit!

  test "public OpenAI completion preserves exact failure metadata without leaking body" do
    expect(Mojentic.HTTPMock, :post, fn url, body, headers, opts ->
      assert url == "https://api.openai.com/v1/chat/completions"

      assert Jason.decode!(body)["messages"] == [
               %{"role" => "user", "content" => "payload-secret"}
             ]

      assert List.keyfind(headers, "Content-Type", 0) == {"Content-Type", "application/json"}
      assert opts[:retry] == false
      assert opts[:redirect] == false

      {:ok,
       %{
         status_code: 503,
         body: ~s({"error":{"code":"overloaded","message":"response-secret"}}),
         headers: [{"x-request-id", "req-actual-17"}, {"retry-after", "7"}]
       }}
    end)

    config = CompletionConfig.new(recovery: [])
    {:error, error} = OpenAI.complete("gpt-4o", [Message.user("payload-secret")], [], config)
    assert error.http_status == 503
    assert error.provider_request_id == "req-actual-17"
    assert error.provider_code == "overloaded"
    assert error.retry_after == {:delay_seconds, 7}
    assert error.wire_attempt == 1
    assert error.retry_eligible
    assert error.resend_permission == :not_granted
    refute inspect(error) =~ "response-secret"
    refute Jason.encode!(error) =~ "response-secret"
  end

  @schema %{"type" => "object", "properties" => %{"answer" => %{"type" => "integer"}}}
  @messages [Message.user("payload-secret")]

  for gateway <- [OpenAI, Ollama, OMLX], operation <- [:complete, :complete_object] do
    @gateway gateway
    @operation operation

    test "#{gateway} #{operation} HTTP status matrix preserves exact metadata and safe lifecycle" do
      for status <- [429, 500, 502, 503, 504, 400, 401] do
        body =
          ~s({"error":{"code":"capacity_exceeded","message":"response-secret tool-secret credential-secret"}})

        response = %{
          status_code: status,
          body: body,
          headers: [{"X-Request-ID", "actual-provider-42"}, {"Retry-After", "9"}]
        }

        expect_request(@gateway, @operation, {:ok, response})
        owner = self()

        config =
          CompletionConfig.new(
            recovery: [observer: fn event -> send(owner, {:lifecycle, event}) end]
          )

        log =
          capture_log(fn ->
            assert {:error, %CompletionError{} = error} = invoke(@gateway, @operation, config)
            assert error.http_status == status
            assert error.provider == provider(@gateway)
            assert error.operation == @operation
            assert error.provider_code == "capacity_exceeded"
            assert error.provider_request_id == "actual-provider-42"
            assert error.retry_after == {:delay_seconds, 9}
            assert error.phase == :awaiting_headers
            assert error.acceptance == :unknown
            assert error.retry_eligible == status in [429, 500, 502, 503, 504]
            assert error.reason == :http_status
            assert error.resend_permission == :not_granted
            assert error.wire_attempt == 1

            assert [%{wire_attempt: 1, attempt_id: attempt_id, logical_request_id: logical_id}] =
                     error.history

            assert attempt_id == error.attempt_id
            assert logical_id == error.logical_request_id
            assert {:ok, ^response} = CompletionError.cause(error)
            assert error.progress.headers_received
            assert error.progress.raw_bytes == byte_size(body)
            assert error.progress.observed == empty_semantic()
            assert error.progress.delivered == empty_semantic()
            assert UUID.info!(error.attempt_id)[:version] == 4
            refute error.attempt_id == error.logical_request_id
            assert_receive {:lifecycle, %{type: :attempt_started, metadata: started}}
            assert started.attempt_id == error.attempt_id
            assert_receive {:lifecycle, %{type: :attempt_failed, metadata: failed}}
            assert failed == CompletionError.safe_metadata(error)
            assert_receive {:lifecycle, %{type: :exhausted, metadata: ^failed}}
            refute_received {:lifecycle, _}

            for safe <- [inspect(error), Jason.encode!(error), inspect(failed)] do
              assert_private(safe)
            end
          end)

        assert_private(log)
      end
    end

    for kind <- [
          :invalid_outer_json,
          :invalid_structured_content,
          :provider_error,
          :parser_exception
        ],
        kind != :invalid_structured_content or operation == :complete_object do
      @kind kind
      test "#{gateway} #{operation} decoding #{@kind} preserves exact cause metadata and ordered identities" do
        {body, cause, observed} = DecodingEvidence.fixture(@gateway, @operation, @kind)
        response = {:ok, %{status_code: 200, body: body, headers: []}}
        owner = self()
        config = CompletionConfig.new(recovery: [observer: &send(owner, {:decoding_event, &1})])
        expect_request(@gateway, @operation, response)

        log =
          capture_log(fn ->
            assert {:error, error} = invoke(@gateway, @operation, config)

            DecodingEvidence.assert_failure(
              error,
              @gateway,
              @operation,
              @kind,
              body,
              cause,
              observed
            )
          end)

        DecodingEvidence.assert_private(log)

        # The same input keeps the legacy parser return or exception unchanged.
        expect_request(@gateway, @operation, response, false)
        assert_legacy_failure(@gateway, @operation, cause)
      end
    end

    if operation == :complete do
      test "#{gateway} complete accepts invalid structured content as unchanged ordinary text" do
        {body, :success, observed} =
          DecodingEvidence.fixture(@gateway, :complete, :invalid_structured_content)

        response = {:ok, %{status_code: 200, body: body, headers: []}}
        expect_request(@gateway, :complete, response, false)
        assert {:ok, legacy} = invoke(@gateway, :complete, CompletionConfig.new())
        expect_request(@gateway, :complete, response)
        owner = self()
        config = CompletionConfig.new(recovery: [observer: &send(owner, {:decoding_event, &1})])

        log =
          capture_log(fn ->
            assert {:ok, ^legacy} = invoke(@gateway, :complete, config)
            assert legacy.content == "response-secret"
            assert legacy.object == nil
            assert legacy.tool_calls == []
            assert legacy.thinking == if(@gateway == OpenAI, do: nil, else: "reasoning-secret")
            empty = DecodingEvidence.empty()
            assert_receive {:decoding_event, started}
            assert started.type == :attempt_started
            assert UUID.info!(started.metadata.logical_request_id)[:version] == 4
            assert UUID.info!(started.metadata.attempt_id)[:version] == 4
            refute started.metadata.logical_request_id == started.metadata.attempt_id

            assert started.metadata == %{
                     logical_request_id: started.metadata.logical_request_id,
                     attempt_id: started.metadata.attempt_id,
                     wire_attempt: 1,
                     phase: :unknown,
                     progress: %{
                       headers_received: false,
                       raw_bytes: 0,
                       observed: empty,
                       delivered: empty
                     }
                   }

            delivered = %{observed | reasoning: @gateway != OpenAI}
            assert_receive {:decoding_event, completed}

            assert completed == %{
                     type: :attempt_succeeded,
                     metadata: %{
                       logical_request_id: started.metadata.logical_request_id,
                       attempt_id: started.metadata.attempt_id,
                       wire_attempt: 1,
                       phase: :decoding,
                       progress: %{
                         headers_received: true,
                         raw_bytes: byte_size(body),
                         observed: observed,
                         delivered: delivered
                       }
                     }
                   }

            refute_received {:decoding_event, _}
            DecodingEvidence.assert_private(inspect([started, completed]))
          end)

        DecodingEvidence.assert_private(log)
      end
    end

    test "#{gateway} #{operation} HTTP boundary preserves transport causes including synthetic unreachable and reset reasons" do
      for {cause, category, phase, acceptance, eligible} <- [
            {%Mint.TransportError{reason: :econnrefused}, :transport, :connecting, :no, true},
            {%Mint.TransportError{reason: :timeout}, :client_timeout, :unknown, :unknown, false},
            {%Req.TransportError{reason: :econnreset}, :transport, :unknown, :unknown, true},
            {%Req.TransportError{reason: :enetunreach}, :transport, :unknown, :unknown, true},
            {%Req.TransportError{reason: :ehostunreach}, :transport, :unknown, :unknown, true},
            {%Req.TransportError{reason: :other}, :transport, :unknown, :unknown, false},
            {{:closed, "credential-secret payload-secret"}, :transport, :unknown, :unknown, true}
          ] do
        expect_request(@gateway, @operation, {:error, cause})
        assert {:error, error} = invoke(@gateway, @operation, CompletionConfig.new(recovery: []))
        assert error.category == category
        assert error.phase == phase
        assert error.acceptance == acceptance
        assert error.retry_eligible == eligible

        expected_reason =
          case cause do
            %{reason: :econnrefused} -> :connection_refused
            %{reason: :timeout} -> :timeout
            %{reason: :other} -> :unclassified_transport
            _ -> :transport_failure
          end

        assert error.reason == expected_reason
        assert error.history == [Map.delete(CompletionError.safe_metadata(error), :history)]
        assert error.http_status == nil
        assert error.retry_after == :absent
        assert error.progress.raw_bytes == 0
        refute error.progress.headers_received
        assert CompletionError.cause(error) === cause
        assert_private(inspect(error))
        assert_private(Mojentic.Error.format_error(error))
        assert_private(Jason.encode!(error))
      end
    end

    test "#{gateway} #{operation} Req transport boundary preserves exact legacy wrapper" do
      cause = %Req.TransportError{reason: :econnrefused}
      expect_request(@gateway, @operation, {:error, cause}, false)

      capture_log(fn ->
        assert {:error, {:request_failed, ^cause}} =
                 invoke(@gateway, @operation, CompletionConfig.new())
      end)
    end

    test "#{gateway} #{operation} validates absent invalid and date metadata" do
      for {headers, expected, request_id, code} <- [
            {[], :absent, nil, "overloaded"},
            {[{"retry-after", "-1"}, {"x-request-id", "bad\ncredential-secret"}], :invalid, nil,
             nil},
            {[{"retry-after", "Fri, 09 Oct 2026 00:00:00 GMT"}, {"x-request-id", "request-99"}],
             {:http_date, "2026-10-09T00:00:00Z"}, "request-99", "overloaded"},
            {[{"retry-after", "garbage"}], :invalid, nil, "overloaded"},
            {[{"retry-after", "1"}, {"Retry-After", "2"}], :invalid, nil, "overloaded"}
          ] do
        provider_code = if code == nil, do: "invalid code credential-secret", else: code
        body = Jason.encode!(%{error: %{code: provider_code}})

        expect_request(
          @gateway,
          @operation,
          {:ok, %{status_code: 429, body: body, headers: headers}}
        )

        assert {:error, error} = invoke(@gateway, @operation, CompletionConfig.new(recovery: []))
        assert error.retry_after == expected
        assert error.provider_request_id == request_id
        assert error.provider_code == code
        assert_private(Jason.encode!(error))
      end
    end

    test "#{gateway} #{operation} unsupported recovery options dispatch no HTTP request" do
      for options <- [
            [max_attempts: 0],
            [admission: fn -> :allow end],
            [unknown: "payload-secret"],
            false,
            ["bad"]
          ] do
        assert {:error, error} =
                 invoke(@gateway, @operation, CompletionConfig.new(recovery: options))

        assert error.reason == :unsupported_options
        assert error.acceptance == :no
        assert error.wire_attempt == 0
        assert error.history == []
        refute error.retry_eligible
        assert_private(inspect(error))
      end
    end

    test "#{gateway} #{operation} opt in success matches legacy successful response and payload" do
      body = successful_body(@gateway, @operation)

      for enabled <- [nil, []] do
        expect_request(
          @gateway,
          @operation,
          {:ok, %{status_code: 200, body: body, headers: []}},
          enabled != nil
        )
      end

      assert invoke(@gateway, @operation, CompletionConfig.new()) ==
               invoke(@gateway, @operation, CompletionConfig.new(recovery: []))
    end

    test "#{gateway} #{operation} cancellation and unknown transport causes are ineligible" do
      for {cause, category, reason} <- [
            {:cancelled, :cancellation, :cancelled},
            {"raw-cause credential-secret", :transport, :unclassified_transport}
          ] do
        expect_request(@gateway, @operation, {:error, cause})
        assert {:error, error} = invoke(@gateway, @operation, CompletionConfig.new(recovery: []))
        assert error.category == category
        assert error.reason == reason
        refute error.retry_eligible
        assert CompletionError.cause(error) == cause
        assert_private(Jason.encode!(error))
      end
    end

    test "#{gateway} #{operation} success events distinguish observed and delivered semantic progress" do
      owner = self()
      body = successful_body(@gateway, @operation)
      expect_request(@gateway, @operation, {:ok, %{status_code: 200, body: body, headers: []}})

      config =
        CompletionConfig.new(
          recovery: [observer: fn event -> send(owner, {:lifecycle, event}) end]
        )

      assert {:ok, _} = invoke(@gateway, @operation, config)
      assert_receive {:lifecycle, %{type: :attempt_started, metadata: started}}
      assert_receive {:lifecycle, %{type: :attempt_succeeded, metadata: completed}}
      assert started.attempt_id == completed.attempt_id
      assert completed.phase == :decoding
      assert completed.wire_attempt == 1
      assert completed.progress.headers_received
      assert completed.progress.raw_bytes == byte_size(body)
      assert completed.progress.observed.content
      assert completed.progress.delivered.content
      refute_received {:lifecycle, _}
    end

    test "#{gateway} #{operation} retains legacy HTTP and transport errors" do
      body = "legacy failure"

      expect_request(
        @gateway,
        @operation,
        {:ok, %{status_code: 401, body: body, headers: []}},
        false
      )

      capture_log(fn ->
        expected = if @gateway == Ollama, do: {:http_error, 401}, else: {:http_error, 401, body}
        assert {:error, ^expected} = invoke(@gateway, @operation, CompletionConfig.new())
      end)

      expect_request(@gateway, @operation, {:error, :closed}, false)

      assert {:error, {:request_failed, :closed}} =
               invoke(@gateway, @operation, CompletionConfig.new())
    end
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    test "#{gateway} broker response generate object and session failures never execute tools or alter caller history" do
      tools = [%CountingTool{owner: self()}]
      broker = Broker.new("gpt-4o", @gateway)
      config = CompletionConfig.new(recovery: [], max_tool_iterations: 1)
      messages = @messages

      for call <- [
            fn -> Broker.generate_response(broker, messages, tools, config) end,
            fn -> Broker.generate(broker, messages, tools, config) end,
            fn -> Broker.generate_object(broker, messages, @schema, config) end
          ] do
        expect(Mojentic.HTTPMock, :post, fn url, body, _headers, opts ->
          assert url == endpoint(@gateway)

          assert Jason.decode!(body)["messages"] == [
                   %{"role" => "user", "content" => "payload-secret"}
                 ]

          assert opts[:retry] == false
          {:ok, %{status_code: 503, body: "response-secret", headers: []}}
        end)

        assert {:error, %CompletionError{http_status: 503, wire_attempt: 1}} = call.()
        refute_received {:tool_executed, _}
        assert messages == @messages
      end

      session = ChatSession.new(broker, tools: tools)
      history = session.messages

      expect(Mojentic.HTTPMock, :post, fn url, body, _headers, opts ->
        assert url == endpoint(@gateway)
        assert List.last(Jason.decode!(body)["messages"])["content"] == "payload-secret"
        assert opts[:retry] == false
        {:ok, %{status_code: 504, body: "response-secret", headers: []}}
      end)

      assert {:error, %CompletionError{http_status: 504}} =
               ChatSession.send(session, "payload-secret", recovery: [])

      assert session.messages == history
      refute_received {:tool_executed, _}
    end

    test "#{gateway} a failure after one tool executes preserves tool result and does not replay it" do
      tracer = start_supervised!({Mojentic.Tracer.TracerSystem, []})
      broker = Broker.new("gpt-4o", @gateway, tracer: tracer)

      tool_message = %{
        content: nil,
        tool_calls: [
          %{
            id: "call-17",
            type: "function",
            function: %{name: "count", arguments: "{\"value\":\"tool-secret\"}"}
          }
        ]
      }

      message =
        if @gateway == Ollama,
          do:
            put_in(tool_message, [:tool_calls, Access.at(0), :function, :arguments], %{
              "value" => "tool-secret"
            }),
          else: tool_message

      body =
        if @gateway == Ollama,
          do: Jason.encode!(%{message: message, model: "response-secret"}),
          else:
            Jason.encode!(%{
              choices: [%{message: message}],
              model: "response-secret",
              usage: %{note: "credential-secret"}
            })

      expect(Mojentic.HTTPMock, :post, fn _url, request, _headers, opts ->
        assert Jason.decode!(request)["messages"] == [
                 %{"role" => "user", "content" => "payload-secret"}
               ]

        assert opts[:retry] == false
        {:ok, %{status_code: 200, body: body, headers: []}}
      end)

      expect(Mojentic.HTTPMock, :post, fn _url, request, _headers, opts ->
        messages = Jason.decode!(request)["messages"]
        assert Enum.map(messages, & &1["role"]) == ["user", "assistant", "tool"]
        assert Jason.decode!(List.last(messages)["content"]) == "tool-result-secret"
        assert hd(messages) == %{"role" => "user", "content" => "payload-secret"}
        [_, assistant, result] = messages

        expected_call =
          if @gateway == Ollama do
            %{
              "type" => "function",
              "function" => %{"name" => "count", "arguments" => %{"value" => "tool-secret"}}
            }
          else
            %{
              "id" => "call-17",
              "type" => "function",
              "function" => %{"name" => "count", "arguments" => ~s({"value":"tool-secret"})}
            }
          end

        expected_assistant = %{"role" => "assistant", "tool_calls" => [expected_call]}
        expected_result = %{"role" => "tool", "content" => Jason.encode!("tool-result-secret")}

        if @gateway == Ollama do
          assert assistant == Map.put(expected_assistant, "content", "")
          assert result == Map.put(expected_result, "tool_calls", [expected_call])
        else
          assert assistant == expected_assistant
          assert result == Map.put(expected_result, "tool_call_id", "call-17")
        end

        assert opts[:retry] == false
        {:ok, %{status_code: 503, body: "response-secret", headers: []}}
      end)

      assert {:error, %CompletionError{http_status: 503, wire_attempt: 1}} =
               Broker.generate(
                 broker,
                 @messages,
                 [%CountingTool{owner: self()}],
                 CompletionConfig.new(recovery: [], max_tool_iterations: 2)
               )

      assert_receive {:tool_executed, %{"value" => "tool-secret"}}
      refute_received {:tool_executed, _}
      events = Mojentic.Tracer.TracerSystem.get_events(tracer)
      assert length(events) == 4
      assert_private(inspect(events))
    end
  end

  test "oMLX structured parsing does not log warning headers on malformed object content" do
    body = successful_body(OMLX, :complete)

    expect_request(
      OMLX,
      :complete_object,
      {:ok, %{status_code: 200, body: body, headers: [{"warning", "credential-secret"}]}}
    )

    log =
      capture_log(fn ->
        assert {:error, %CompletionError{category: :protocol}} =
                 invoke(OMLX, :complete_object, CompletionConfig.new(recovery: []))
      end)

    assert_private(log)
  end

  test "OpenAI parameter adaptation logs exclude the requested model and payload" do
    expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, opts ->
      assert Jason.decode!(body)["model"] == "credential-secret"

      assert Jason.decode!(body)["messages"] == [
               %{"role" => "user", "content" => "payload-secret"}
             ]

      assert opts[:retry] == false
      {:ok, %{status_code: 503, body: "response-secret", headers: []}}
    end)

    log =
      capture_log(fn ->
        assert {:error, %CompletionError{}} =
                 OpenAI.complete(
                   "credential-secret",
                   @messages,
                   [],
                   CompletionConfig.new(recovery: [], reasoning_effort: :low)
                 )
      end)

    assert log =~ "parameter adaptation warning"
    assert_private(log)
  end

  for gateway <- [OpenAI, Ollama, OMLX] do
    @gateway gateway
    test "#{gateway} structured failure records observed completed tools without delivering them" do
      message = %{
        content: "response-secret",
        tool_calls: [
          %{
            id: "call-17",
            type: "function",
            function: %{name: "count", arguments: ~s({"value":"tool-secret"})}
          }
        ]
      }

      body =
        if @gateway == Ollama,
          do: Jason.encode!(%{message: message}),
          else: Jason.encode!(%{choices: [%{message: message}]})

      expect_request(
        @gateway,
        :complete_object,
        {:ok, %{status_code: 200, body: body, headers: []}}
      )

      assert {:error, error} =
               invoke(@gateway, :complete_object, CompletionConfig.new(recovery: []))

      assert error.progress.observed.completed_tool_calls == 1
      assert error.progress.delivered.completed_tool_calls == 0
      assert error.progress.delivered.tool_fragments == 0
      assert_private(inspect(error))
      assert_private(Jason.encode!(error))
    end
  end

  test "tool depth remains bounded when recovery errors are enabled" do
    broker = Broker.new("gpt-4o", OpenAI)

    tool_message = %{
      content: nil,
      tool_calls: [
        %{
          id: "call-17",
          type: "function",
          function: %{name: "count", arguments: ~s({"value":"tool-secret"})}
        }
      ]
    }

    response = %{
      status_code: 200,
      body: Jason.encode!(%{choices: [%{message: tool_message}]}),
      headers: []
    }

    expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, opts ->
      assert Enum.map(Jason.decode!(body)["messages"], & &1["role"]) == ["user"]
      assert opts[:retry] == false
      {:ok, response}
    end)

    expect(Mojentic.HTTPMock, :post, fn _url, body, _headers, opts ->
      assert Enum.map(Jason.decode!(body)["messages"], & &1["role"]) == [
               "user",
               "assistant",
               "tool"
             ]

      assert opts[:retry] == false
      {:ok, response}
    end)

    assert {:error, :max_tool_iterations_exceeded} =
             Broker.generate(
               broker,
               @messages,
               [%CountingTool{owner: self()}],
               CompletionConfig.new(recovery: [], max_tool_iterations: 1)
             )

    assert_receive {:tool_executed, %{"value" => "tool-secret"}}
    refute_received {:tool_executed, _}
  end

  defp expect_request(gateway, operation, response, enabled \\ true) do
    expect(Mojentic.HTTPMock, :post, fn url, body, headers, opts ->
      assert url == endpoint(gateway)
      assert Jason.decode!(body) == expected_payload(gateway, operation)
      assert List.keyfind(headers, "Content-Type", 0) == {"Content-Type", "application/json"}
      assert opts[:retry] == if(enabled, do: false, else: nil)
      assert opts[:redirect] == if(enabled, do: false, else: nil)
      response
    end)
  end

  defp invoke(gateway, :complete, config), do: gateway.complete("gpt-4o", @messages, [], config)

  defp invoke(gateway, :complete_object, config),
    do: gateway.complete_object("gpt-4o", @messages, @schema, config)

  defp assert_legacy_failure(gateway, operation, %{__exception__: true} = cause) do
    raised =
      assert_raise cause.__struct__, fn ->
        invoke(gateway, operation, CompletionConfig.new())
      end

    assert raised === cause
  end

  defp assert_legacy_failure(gateway, operation, cause) do
    assert invoke(gateway, operation, CompletionConfig.new()) === {:error, cause}
  end

  defp provider(OpenAI), do: :openai
  defp provider(Ollama), do: :ollama
  defp provider(OMLX), do: :omlx
  defp endpoint(OpenAI), do: "https://api.openai.com/v1/chat/completions"
  defp endpoint(Ollama), do: "http://localhost:11434/api/chat"
  defp endpoint(OMLX), do: "http://localhost:8000/v1/chat/completions"

  defp expected_payload(gateway, operation) do
    base = %{
      "model" => "gpt-4o",
      "messages" => [%{"role" => "user", "content" => "payload-secret"}]
    }

    base =
      case gateway do
        Ollama ->
          Map.merge(base, %{
            "stream" => false,
            "options" => %{"temperature" => 1.0, "num_ctx" => 32_768, "num_predict" => 16_384}
          })

        _ ->
          Map.merge(base, %{"temperature" => 1.0, "max_tokens" => 16_384})
      end

    case {gateway, operation} do
      {_, :complete} ->
        base

      {Ollama, :complete_object} ->
        Map.put(base, "format", @schema)

      {OMLX, :complete_object} ->
        Map.put(base, "response_format", %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "response", "schema" => @schema}
        })

      {OpenAI, :complete_object} ->
        Map.put(base, "response_format", %{
          "type" => "json_schema",
          "json_schema" => %{"name" => "response", "schema" => @schema}
        })
    end
  end

  defp successful_body(gateway, operation) do
    content = if operation == :complete_object, do: ~s({"answer":42}), else: "answer"

    case gateway do
      Ollama ->
        Jason.encode!(%{
          message: %{content: content},
          model: "actual-model",
          done_reason: "stop",
          eval_count: 3
        })

      _ ->
        Jason.encode!(%{
          choices: [%{message: %{content: content}, finish_reason: "stop"}],
          model: "actual-model",
          usage: %{completion_tokens: 3}
        })
    end
  end

  defp empty_semantic,
    do: %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}

  defp assert_private(text) do
    for secret <- [
          "payload-secret",
          "response-secret",
          "credential-secret",
          "tool-secret",
          "reasoning-secret"
        ] do
      refute text =~ secret
    end
  end
end
