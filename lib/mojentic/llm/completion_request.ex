defmodule Mojentic.LLM.CompletionRequest do
  @moduledoc false
  alias Mojentic.LLM.CompletionError

  @provider_codes ~w(overloaded capacity_exceeded busy bad_request rate_limit_exceeded
                     insufficient_quota invalid_api_key authentication_error invalid_request_error
                     model_not_found server_error context_length_exceeded)

  def run(client, url, body, headers, opts, config, {provider, operation}, parse) do
    case config.recovery do
      nil ->
        parse.(client.post(url, body, headers, opts))

      recovery ->
        Mojentic.LLM.Recovery.run(recovery, provider, operation, fn ids, deadline ->
          attempt(
            client,
            {url, body, headers, opts},
            recovery,
            provider,
            operation,
            parse,
            ids,
            deadline
          )
        end)
    end
  end

  defp attempt(
         client,
         {url, body, headers, opts},
         recovery,
         provider,
         operation,
         parse,
         ids,
         deadline
       ) do
    started = fn ->
      emit(
        recovery,
        :attempt_started,
        Map.merge(ids, %{phase: :unknown, progress: progress(nil, "")})
      )
    end

    tracker = self()

    result =
      Mojentic.LLM.Recovery.request(
        recovery,
        deadline,
        {started,
         fn ->
           client.post(
             url,
             body,
             headers,
             Keyword.merge(opts,
               retry: false,
               redirect: false,
               recovery_metadata: true,
               wire_trace: trace(recovery, ids),
               received_observer:
                 if(recovery[:cancel_ref],
                   do: fn evidence -> send(tracker, {:request_evidence, self(), evidence}) end
                 )
             )
           )
         end}
      )

    case result do
      {:not_sent, reason} ->
        {:not_sent, reason}

      {:error, {:request_cancelled, evidence, progress, original}} ->
        cancelled(evidence, progress, original, provider, operation, ids, {body, headers})

      response ->
        finish(response, parse, recovery, provider, operation, ids, {body, headers})
    end
  end

  @doc false
  def cancelled(evidence, snapshot, original, provider, operation, ids, outbound \\ nil) do
    evidence = evidence || Mojentic.HTTP.ReceivedEvidence.new(:ordinary)

    response =
      if evidence.status,
        do:
          {:ok,
           %{
             status_code: evidence.status,
             headers: evidence.headers,
             body: evidence.body,
             phase: :streaming
           }},
        else: {:error, :cancelled}

    error = build(response, :cancelled, provider, operation, ids, outbound)
    progress = Mojentic.HTTP.ReceivedEvidence.progress(evidence)

    progress = merge_received_progress(progress, snapshot)

    semantic = progress.observed

    interrupted =
      operation in [:complete_stream, :complete_stream_events] and
        (semantic.content or semantic.reasoning or semantic.tool_fragments > 0)

    cause = cancellation_cause(original, evidence.cause)

    error = %{
      error
      | progress: progress,
        reason: if(interrupted, do: :stream_interrupted, else: :cancelled),
        phase: if(progress.headers_received, do: :streaming, else: error.phase),
        private_cause: fn -> cause end,
        private_evidence: fn ->
          Map.take(evidence, [:status, :headers, :body]) |> Map.put(:ids, ids)
        end
    }

    {:error, %{error | history: [Map.delete(CompletionError.safe_metadata(error), :history)]}}
  end

  defp merge_received_progress(progress, nil), do: progress

  defp merge_received_progress(progress, snapshot) do
    observed =
      Map.merge(progress.observed, snapshot.progress.observed, fn
        _key, left, right when is_boolean(left) -> left or right
        _key, left, right -> max(left, right)
      end)

    %{progress | observed: observed, delivered: snapshot.progress.delivered}
  end

  # Received evidence precedes POST normalization and retains the native cause.
  # A returned HTTP result must not replace it during cancellation handoff.
  defp cancellation_cause(_result, cause) when not is_nil(cause), do: original_cause(cause)

  defp cancellation_cause({:error, %CompletionError{} = error}, _cause),
    do: CompletionError.cause(error)

  defp cancellation_cause({:error, cause}, _received), do: original_cause(cause)
  defp cancellation_cause(_result, received), do: original_cause(received || :cancelled)

  defp original_cause({:http_response, _status, _headers, _body, cause}),
    do: original_cause(cause)

  defp original_cause(%Finch.TransportError{source: source}), do: source
  defp original_cause(cause), do: cause

  @doc false
  def trace(recovery, ids) do
    case Keyword.get(recovery, :trace_observer) do
      nil -> nil
      callback -> {callback, ids}
    end
  end

  @doc false
  def unsupported(provider, operation, ids) do
    error = build(nil, :unsupported_options, provider, operation, ids)
    {:error, %{error | wire_attempt: 0, history: []}}
  end

  defp finish(
         {:ok, %{status_code: 200} = response} = received,
         parse,
         opts,
         provider,
         operation,
         ids,
         outbound
       ) do
    decoded = decode(parse, received)

    if Mojentic.LLM.Recovery.cancelled?(opts) do
      evidence = %{
        Mojentic.HTTP.ReceivedEvidence.new(:ordinary)
        | status: response.status_code,
          headers: response.headers,
          body: response.body
      }

      cancelled(evidence, nil, decoded, provider, operation, ids, outbound)
    else
      finish_decoded(decoded, received, opts, provider, operation, ids, outbound)
    end
  end

  defp finish(
         {:error, {:http_response, status, headers, body, cause}},
         _parse,
         _opts,
         provider,
         operation,
         ids,
         outbound
       ) do
    response = {:ok, %{status_code: status, headers: headers, body: body, phase: :streaming}}
    {:error, build(response, cause, provider, operation, ids, outbound)}
  end

  defp finish({:error, cause} = response, _parse, _opts, provider, operation, ids, outbound) do
    {:error, build(response, cause, provider, operation, ids, outbound)}
  end

  defp finish(response, _parse, _opts, provider, operation, ids, outbound) do
    {:error, build(response, response, provider, operation, ids, outbound)}
  end

  defp finish_decoded(
         {:ok, completion} = success,
         {:ok, response} = received,
         opts,
         _provider,
         _operation,
         ids,
         _outbound
       ) do
    progress = progress(received, response.body)

    delivered = %{
      content: present?(completion.content),
      reasoning: present?(completion.thinking),
      tool_fragments: 0,
      completed_tool_calls: length(completion.tool_calls)
    }

    emit(
      opts,
      :attempt_succeeded,
      Map.merge(ids, %{
        wire_attempt: ids.wire_attempt,
        phase: :decoding,
        progress: %{progress | delivered: delivered}
      })
    )

    success
  end

  defp finish_decoded({:error, cause}, response, _opts, provider, operation, ids, outbound),
    do: {:error, build(response, cause, provider, operation, ids, outbound)}

  defp decode(parse, response) do
    parse.(response)
  rescue
    exception -> {:error, exception}
  end

  defp emit(opts, type, metadata) do
    case Keyword.get(opts, :observer) do
      nil -> :ok
      callback -> callback.(%{type: type, metadata: metadata})
    end
  end

  @doc false
  def build(response, cause, provider, operation, ids, outbound \\ nil) do
    {category, status, phase, acceptance, reason, eligible} = classify(response, cause)
    {headers, body} = evidence(response)

    status =
      case response do
        {:ok, %{status_code: received}} -> received
        _ -> status
      end

    error =
      struct!(
        CompletionError,
        Map.merge(ids, %{
          category: category,
          provider: provider,
          operation: operation,
          http_status: status,
          phase: phase,
          acceptance: acceptance,
          reason: reason,
          retry_eligible: eligible,
          provider_code: safe_code(body, outbound),
          provider_request_id: safe_request_id(header(headers, "x-request-id"), outbound),
          retry_after: retry_after(header(headers, "retry-after")),
          progress: progress(response, body),
          private_cause: fn -> cause end,
          private_evidence: fn -> %{status: status, headers: headers, body: body, ids: ids} end
        })
      )

    %{error | history: [CompletionError.safe_metadata(error) |> Map.delete(:history)]}
  end

  defp classify(_response, :cancelled),
    do: {:cancellation, nil, :unknown, :unknown, :cancelled, false}

  defp classify(_response, :capture_failed),
    do: {:protocol, nil, :unknown, :unknown, :capture_failed, false}

  defp classify(_response, :unsupported_options),
    do: {:protocol, nil, :unknown, :no, :unsupported_options, false}

  # An interrupted 200 body is transport evidence, never a decoded completion.
  # Non-2xx responses retain HTTP precedence in the status clause below.
  defp classify({:ok, %{status_code: 200, phase: :streaming}}, cause) do
    {category, _status, _phase, acceptance, reason, eligible} = classify({:error, cause}, cause)
    {category, 200, :streaming, acceptance, reason, eligible}
  end

  defp classify({:ok, %{status_code: 200, body: body}}, _cause) do
    case Jason.decode(body) do
      {:ok, %{"error" => _error}} ->
        {:provider_response, 200, :decoding, :yes, :provider_error, false}

      _ ->
        {:protocol, 200, :decoding, :yes, :malformed_response, false}
    end
  end

  defp classify({:ok, %{status_code: status} = response}, _cause),
    do:
      {:http, status, Map.get(response, :phase, :awaiting_headers), :unknown, :http_status,
       status in [429, 500, 502, 503, 504]}

  defp classify({:error, cause}, _original) when cause in [:timeout, :etimedout],
    do: {:client_timeout, nil, :unknown, :unknown, :timeout, false}

  # Req preserves the reason but wraps Mint failures in its own exception.
  # Receive failures do not establish whether inference was accepted or stopped.
  defp classify({:error, %Req.TransportError{reason: :timeout}}, _original),
    do: {:client_timeout, nil, :unknown, :unknown, :timeout, false}

  defp classify({:error, %Req.TransportError{reason: :econnrefused}}, _original),
    do: {:transport, nil, :connecting, :no, :connection_refused, true}

  defp classify({:error, %Req.TransportError{reason: reason}}, _original)
       when reason in [:closed, :econnreset, :enetunreach, :ehostunreach],
       do: {:transport, nil, :unknown, :unknown, :transport_failure, true}

  defp classify({:error, %Mint.TransportError{reason: :timeout}}, _original),
    do: {:client_timeout, nil, :unknown, :unknown, :timeout, false}

  defp classify({:error, %Mint.TransportError{reason: :econnrefused}}, _original),
    do: {:transport, nil, :connecting, :no, :connection_refused, true}

  defp classify({:error, :cancelled}, _original),
    do: {:cancellation, nil, :unknown, :unknown, :cancelled, false}

  defp classify({:error, %Mint.TransportError{reason: reason}}, _original)
       when reason in [:closed, :econnreset, :enetunreach, :ehostunreach],
       do: {:transport, nil, :unknown, :unknown, :transport_failure, true}

  defp classify({:error, {:closed, _detail}}, _original),
    do: {:transport, nil, :unknown, :unknown, :transport_failure, true}

  defp classify({:error, reason}, _original) when reason in [:closed, :econnreset],
    do: {:transport, nil, :unknown, :unknown, :transport_failure, true}

  defp classify({:error, _cause}, _original),
    do: {:transport, nil, :unknown, :unknown, :unclassified_transport, false}

  defp evidence({:ok, response}), do: {Map.get(response, :headers, []), response.body}
  defp evidence(_response), do: {[], ""}

  defp progress(response, body) do
    semantic = semantic(body)

    %{
      headers_received: match?({:ok, _}, response),
      raw_bytes: byte_size(body),
      observed: semantic,
      delivered: %{reasoning: false, content: false, tool_fragments: 0, completed_tool_calls: 0}
    }
  end

  defp semantic(body) do
    message =
      case Jason.decode(body) do
        {:ok, %{"message" => message}} when is_map(message) -> message
        {:ok, %{"choices" => [%{"message" => message} | _]}} when is_map(message) -> message
        _ -> %{}
      end

    calls = Map.get(message, "tool_calls", [])

    %{
      content: present?(message["content"]),
      reasoning: present?(message["thinking"] || message["reasoning_content"]),
      tool_fragments: 0,
      completed_tool_calls: completed_calls(calls)
    }
  end

  defp completed_calls(calls) when is_list(calls), do: Enum.count(calls, &complete_call?/1)
  defp completed_calls(_calls), do: 0

  defp complete_call?(%{"function" => %{"name" => name, "arguments" => arguments}})
       when is_binary(name) and byte_size(name) > 0 do
    case arguments do
      map when is_map(map) -> true
      text when is_binary(text) -> match?({:ok, map} when is_map(map), Jason.decode(text))
      _ -> false
    end
  end

  defp complete_call?(_call), do: false

  defp present?(value), do: is_binary(value) and byte_size(value) > 0

  defp header(headers, name) do
    case Enum.filter(headers, fn {key, _} -> String.downcase(key) == name end) do
      [{_, value}] when is_binary(value) -> value
      [] -> nil
      _ -> :invalid
    end
  end

  defp validated(value) when is_binary(value) do
    if byte_size(value) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value), do: value
  end

  defp validated(_value), do: nil

  # Provider text is untrusted even when its syntax resembles a code or UUID.
  # Compare against the exact outbound representation and decoded payload strings.
  # Local logical/attempt IDs never pass through this provider-only boundary.
  defp safe_code(body, outbound) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}}
      when code in @provider_codes ->
        without_echo(code, outbound)

      _ ->
        nil
    end
  end

  defp safe_request_id(value, outbound) do
    case validated(value) do
      nil -> nil
      value -> without_echo(value, outbound)
    end
  end

  defp without_echo(value, nil), do: value

  defp without_echo(value, {body, headers}) do
    {payload, token_sources} = payload_strings(body)
    supplied_headers = Enum.flat_map(headers, &header_strings/1)
    strings = payload ++ supplied_headers
    tokens = Enum.flat_map(token_sources ++ supplied_headers, &tokens/1)

    if Enum.any?(strings, &echo?(value, &1)) or Enum.any?(tokens, &token_echo?(value, &1)),
      do: nil,
      else: value
  end

  defp echo?(value, text) do
    text != "" and (String.contains?(text, value) or String.contains?(value, text))
  end

  defp header_strings({_key, text}) do
    # Include the credential separately from its HTTP authorization scheme.
    [text | String.split(text, " ", parts: 2)]
  end

  defp payload_strings(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        decoded_strings = strings(decoded)
        {[body | decoded_strings], decoded_strings}

      _ ->
        {[body], [body]}
    end
  end

  defp strings(value) when is_binary(value), do: [value]

  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)

  defp strings(value) when is_map(value),
    do: Enum.flat_map(value, fn {key, item} -> strings(key) ++ strings(item) end)

  defp strings(_value), do: []

  defp tokens(text), do: Regex.scan(~r/[A-Za-z0-9_-]+/, text) |> List.flatten()

  defp token_echo?(value, token) do
    # Short words in prose must occur as identifier components, not single
    # letters inside an unrelated provider code (for example the article "a").
    if byte_size(token) >= 8 or token in @provider_codes or Regex.match?(~r/[0-9_-]/, token) do
      String.contains?(value, token)
    else
      Regex.match?(
        Regex.compile!("(?:^|[^A-Za-z0-9])" <> Regex.escape(token) <> "(?:$|[^A-Za-z0-9])"),
        value
      )
    end
  end

  defp retry_after(nil), do: :absent
  defp retry_after(:invalid), do: :invalid

  defp retry_after(value) do
    if Regex.match?(~r/\A[0-9]+\z/, value),
      do: {:delay_seconds, String.to_integer(value)},
      else: parse_date(value)
  end

  defp parse_date(value) do
    case Req.Utils.parse_http_date(value) do
      {:ok, date} -> {:http_date, DateTime.to_iso8601(date)}
      _ -> :invalid
    end
  end
end
