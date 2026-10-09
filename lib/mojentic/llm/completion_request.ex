defmodule Mojentic.LLM.CompletionRequest do
  @moduledoc false
  alias Mojentic.LLM.CompletionError

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
               wire_trace: trace(recovery, ids)
             )
           )
         end}
      )

    case result do
      {:not_sent, reason} -> {:not_sent, reason}
      response -> finish(response, parse, recovery, provider, operation, ids)
    end
  end

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

  defp finish({:ok, %{status_code: 200}} = response, parse, opts, provider, operation, ids) do
    case decode(parse, response) do
      {:ok, completion} = success ->
        {:ok, wire_response} = response
        progress = progress(response, wire_response.body)

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

      {:error, cause} ->
        {:error, build(response, cause, provider, operation, ids)}
    end
  end

  defp finish(
         {:error, {:http_response, status, headers, body, cause}},
         _parse,
         _opts,
         provider,
         operation,
         ids
       ) do
    response = {:ok, %{status_code: status, headers: headers, body: body, phase: :streaming}}
    {:error, build(response, cause, provider, operation, ids)}
  end

  defp finish({:error, cause} = response, _parse, _opts, provider, operation, ids) do
    {:error, build(response, cause, provider, operation, ids)}
  end

  defp finish(response, _parse, _opts, provider, operation, ids) do
    {:error, build(response, response, provider, operation, ids)}
  end

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
  def build(response, cause, provider, operation, ids) do
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
          provider_code: provider_code(body),
          provider_request_id: validated(header(headers, "x-request-id")),
          retry_after: retry_after(header(headers, "retry-after")),
          progress: progress(response, body),
          private_cause: fn -> cause end
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

  defp provider_code(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} -> validated(code)
      _ -> nil
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
