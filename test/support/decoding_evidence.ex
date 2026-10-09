defmodule Mojentic.TestSupport.DecodingEvidence do
  @moduledoc false
  import ExUnit.Assertions
  alias Mojentic.LLM.CompletionError
  alias Mojentic.LLM.Gateways.{OpenAI, Ollama, OMLX}

  def empty do
    %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}
  end

  def fixture(_gateway, _operation, :invalid_outer_json) do
    {"response-secret credential-secret tool-secret reasoning-secret", :invalid_response, empty()}
  end

  def fixture(gateway, operation, :invalid_structured_content) do
    message = %{
      content: "response-secret",
      thinking: "reasoning-secret",
      reasoning_content: "reasoning-secret",
      tool_calls: []
    }

    cause = if operation == :complete_object, do: :invalid_json_object, else: :success
    {envelope(gateway, message), cause, %{empty() | content: true, reasoning: true}}
  end

  def fixture(_gateway, _operation, :provider_error) do
    body =
      Jason.encode!(%{
        error: %{
          code: "bad_request",
          message: "response-secret credential-secret tool-secret reasoning-secret"
        }
      })

    {body, :invalid_response, empty()}
  end

  def fixture(gateway, :complete, :parser_exception) when gateway in [OpenAI, Ollama] do
    {envelope(gateway, "response-secret"), %BadMapError{term: "response-secret"}, empty()}
  end

  def fixture(OMLX, :complete, :parser_exception) do
    message = %{content: "response-secret", reasoning_content: "reasoning-secret", tool_calls: 17}
    cause = %Protocol.UndefinedError{protocol: Enumerable, value: 17, description: ""}
    {envelope(OMLX, message), cause, %{empty() | content: true, reasoning: true}}
  end

  def fixture(gateway, :complete_object, :parser_exception) do
    {envelope(gateway, %{content: 17}), argument_error(), empty()}
  end

  defp argument_error do
    %ArgumentError{
      message:
        "errors were found at the given arguments:\n\n  * 1st argument: not an iodata term\n"
    }
  end

  defp envelope(Ollama, message), do: Jason.encode!(%{message: message})
  defp envelope(_gateway, message), do: Jason.encode!(%{choices: [%{message: message}]})

  def assert_failure(
        error,
        gateway,
        operation,
        kind,
        body,
        cause,
        observed,
        response_metadata \\ {nil, :absent}
      ) do
    {request_id, retry_after} = response_metadata
    assert %CompletionError{} = error
    assert CompletionError.cause(error) === cause
    assert error.provider == provider(gateway)
    assert error.operation == operation
    assert error.category == if(kind == :provider_error, do: :provider_response, else: :protocol)

    assert error.reason ==
             if(kind == :provider_error, do: :provider_error, else: :malformed_response)

    assert error.http_status == 200
    assert error.phase == :decoding
    assert error.acceptance == :yes
    assert error.retry_eligible == false
    assert error.resend_permission == :not_granted
    assert error.wire_attempt == 1
    assert error.provider_code == if(kind == :provider_error, do: "bad_request", else: nil)
    assert error.provider_request_id == request_id
    assert error.retry_after == retry_after

    assert error.progress == %{
             headers_received: true,
             raw_bytes: byte_size(body),
             observed: observed,
             delivered: empty()
           }

    assert UUID.info!(error.logical_request_id)[:version] == 4
    assert UUID.info!(error.attempt_id)[:version] == 4
    refute error.logical_request_id == error.attempt_id

    safe = CompletionError.safe_metadata(error)
    assert error.history == [Map.delete(safe, :history)]

    started = %{
      logical_request_id: error.logical_request_id,
      attempt_id: error.attempt_id,
      wire_attempt: 1,
      phase: :unknown,
      progress: %{headers_received: false, raw_bytes: 0, observed: empty(), delivered: empty()}
    }

    for expected <- [
          %{type: :attempt_started, metadata: started},
          %{type: :attempt_failed, metadata: safe},
          %{type: :exhausted, metadata: safe}
        ] do
      assert_receive {:decoding_event, actual}
      assert actual === expected
      assert_private(inspect(actual))
    end

    refute_received {:decoding_event, _}

    for rendered <- [
          inspect(error),
          Jason.encode!(error),
          Mojentic.Error.format_error(error),
          inspect(safe)
        ],
        do: assert_private(rendered)
  end

  def assert_private(rendered) do
    for secret <- [
          "payload-secret",
          "response-secret",
          "reasoning-secret",
          "credential-secret",
          "tool-secret"
        ],
        do: refute(rendered =~ secret)
  end

  defp provider(OpenAI), do: :openai
  defp provider(Ollama), do: :ollama
  defp provider(OMLX), do: :omlx
end
