defmodule Mojentic.LLM.Recovery do
  @moduledoc """
  Bounded, opt-in recovery of a single immutable provider completion.

  Without an admission hook, eligible OpenAI failures may retry. Ollama and oMLX
  require admission unless transport evidence establishes `acceptance: :no`
  (for example, connection refusal). Otherwise recovery stops with
  `resend_permission: :admission_required` and an `:admission_required` event.
  HTTP errors and local socket closure do not establish nonacceptance.
  This policy applies to ordinary, structured, event and legacy streams,
  including Broker and ChatSession. Eligibility, semantic replay restrictions,
  cancellation, deadlines and the attempt limit still apply. `recovery: []`
  keeps the default single attempt; `max_attempts` must opt into resends.

  Admission receives safe failure metadata, correlation IDs, progress, and a
  `reply_to` PID and `ref`. Return `:allow`, `:reject`, or `:pending`; resolve
  pending decisions with `{:recovery_admission, ref, :allow | :reject}`.
  A hook that returns anything else, raises, throws, exits, or dies before
  deciding ends recovery with `resend_permission: :admission_no_decision` and
  an `:admission_no_decision` lifecycle event. Explicit `:reject` retains
  `:rejected` and `:admission_rejected`. Neither authorizes a resend. Callback
  failures are payload-free; the original provider failure and history remain.
  `:pending` continues waiting for an explicit decision, cancellation or deadline.
  Send `{:cancel, cancel_ref}` to the completion caller to cancel locally.
  Local HTTP cancellation never proves remote inference termination.

  Retry-After accepts delay seconds and all HTTP-date forms: IMF-fixdate,
  RFC 850 and asctime. Dates are normalized to UTC ISO 8601 in safe metadata.
  The remaining delay uses the observed wall clock; past dates contribute zero.
  Invalid or absent headers retain the jittered policy delay. A valid value is
  a minimum: recovery uses the greater of it and the policy delay, and refuses
  resends that exceed the delay ceiling or reach the remaining recovery budget.

  ## Exact wire evidence

  `trace_observer: callback` explicitly opts into sensitive evidence at ReqClient.
  The callback must return `:ok`; any other return or raised/thrown/exited failure
  produces a terminal, payload-free `:capture_failed` completion error. Persistence
  is caller-owned. No persistent library storage, masking or automatic trace logging occurs.
  Broker and ChatSession forward this option through their completion config.

  Each event has `ids: %{logical_request_id: id, attempt_id: id, wire_attempt: n}`
  with the exact identities used by lifecycle metadata and error history:

  * `:request`: `method`, `url`, supplied `headers`, exact encoded `body`.
  * `:response_headers`: observed HTTP `status` and flattened `headers`.
  * `:response_data`: exact binary `body` chunk exposed by the HTTP client,
    including non-2xx and partially received bodies, before provider decoding.
  * `:response_end`: `outcome` (`:complete`, `:failed`, `:consumer_halted`) and
    `evidence` (`:available` after headers/data, otherwise `:unavailable`). An
    empty observed body has headers but no data; it is not unavailable evidence.

  This is application HTTP evidence, not TLS packets, transfer framing, or every
  generated transport header. Chunks can be coalesced by the HTTP client. A
  parser can stop before EOF; `:consumer_halted` reports that capture limit rather
  than claiming a complete response. Callback failure itself can prevent terminal
  notification. Request notification occurs at authorized dispatch, before waiting
  for response headers. A dispatched request retains its independent exact evidence
  when cancelled before headers; an undispatched cancellation produces no trace.
  Authoritative cancellation
  kills a blocked capture worker, so terminal capture delivery is not guaranteed
  on cancellation. No extra read, resend or model request fills missing evidence.
  With `cancel_ref`, ReqClient records received status, headers and bytes before
  capture callbacks, independently of delivered progress. Cancellation errors retain
  this sensitive response in memory via `CompletionError.received_evidence/1`;
  inspection, JSON and lifecycle events omit it. Original typed causes, when
  available, remain accessible through `CompletionError.cause/1`. There is no extra
  provider read or resend. Stream terminal acceptance requires consumer demand after
  final capture/cleanup; cancellation before acceptance prevents success.
  A paused enumerator cannot forward mailbox cancellation until it resumes. For
  prompt cancellation while paused, retain the recovery-owner PID from the
  `attempt_started` observer (`self()` inside that observer) and send to it directly.
  Custom HTTP behaviours must implement `:wire_trace` and `:received_observer` to provide exact evidence;
  these guarantees apply to the default ReqClient boundary.
  """
  alias Mojentic.LLM.{CompletionError, CompletionRequest}

  @max_timer_delay 4_294_967_295

  @defaults [
    max_attempts: 1,
    base_delay: 100,
    delay_ceiling: 30_000,
    retryable_categories: [:transport, :http],
    retryable_statuses: [429, 500, 502, 503, 504]
  ]

  @doc "Capabilities implemented by the adapter completion boundaries."
  @spec capabilities(:openai | :ollama | :omlx) :: map()
  def capabilities(provider) when provider in [:openai, :ollama, :omlx] do
    %{
      local_request_cancellation: :supported,
      remote_request_cancellation: :unsupported,
      request_status: :unsupported,
      idempotency: :unsupported,
      exact_attempt_termination: :unknown
    }
  end

  @doc false
  def run(opts, provider, operation, attempt) do
    ids = %{logical_request_id: UUID.uuid4(), attempt_id: UUID.uuid4(), wire_attempt: 0}

    if valid_options?(opts) do
      policy = Keyword.merge(@defaults, opts)
      state = %{ids: ids, history: [], deadline: policy[:deadline], error: nil, retry_minimum: 0}
      loop(policy, provider, operation, attempt, state)
    else
      CompletionRequest.unsupported(provider, operation, ids)
    end
  end

  @doc false
  def valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and Enum.all?(opts, &valid_option?/1)
  end

  def valid_options?(_), do: false
  defp valid_option?({:max_attempts, n}), do: is_integer(n) and n > 0

  defp valid_option?({key, n}) when key in [:base_delay, :delay_ceiling, :budget],
    do: is_integer(n) and n >= 0

  defp valid_option?({:deadline, n}), do: is_integer(n)

  defp valid_option?({key, callback})
       when key in [:observer, :trace_observer, :admission, :jitter, :sleeper],
       do: is_function(callback, 1)

  defp valid_option?({key, callback}) when key in [:clock, :wall_clock],
    do: is_function(callback, 0)

  defp valid_option?({:cancel_ref, ref}), do: is_reference(ref)

  defp valid_option?({:retryable_categories, values}),
    do: is_list(values) and Enum.all?(values, &(&1 in [:transport, :http, :client_timeout]))

  defp valid_option?({:retryable_statuses, values}),
    do: is_list(values) and Enum.all?(values, &(is_integer(&1) and &1 in 400..599))

  defp valid_option?(_), do: false

  defp loop(opts, provider, operation, attempt, state) do
    case guard_send(opts, state.deadline) do
      :ok ->
        ids = %{state.ids | attempt_id: UUID.uuid4(), wire_attempt: state.ids.wire_attempt + 1}

        case attempt.(ids, state.deadline) do
          {:ok, _} = success ->
            success

          {:not_sent, reason} ->
            terminal(opts, stopped(state, provider, operation, reason))

          {:error, error} ->
            history = state.history ++ error.history
            error = %{error | history: history}
            deadline = first_deadline(opts, state)

            state = %{
              state
              | ids: ids,
                history: history,
                error: error,
                deadline: deadline,
                retry_minimum: retry_after(opts, error.retry_after)
            }

            emit(opts, :attempt_failed, CompletionError.safe_metadata(error))
            recover(opts, provider, operation, attempt, state)
        end

      reason ->
        terminal(opts, stopped(state, provider, operation, reason))
    end
  end

  defp first_deadline(opts, %{error: nil, deadline: deadline}) do
    case opts[:budget] do
      nil -> deadline
      budget -> earlier(deadline, now(opts) + budget)
    end
  end

  defp first_deadline(_opts, state), do: state.deadline
  defp earlier(nil, value), do: value
  defp earlier(left, right), do: min(left, right)

  defp recover(opts, provider, operation, attempt, state) do
    cond do
      state.ids.wire_attempt >= opts[:max_attempts] -> terminal(opts, state.error)
      not eligible?(opts, state.error) -> terminal(opts, state.error)
      true -> retry(opts, provider, operation, attempt, state)
    end
  end

  defp eligible?(opts, error) do
    error.http_status not in [400, 401, 403] and
      error.reason != :stream_interrupted and safe_stream_failure?(error) and
      error.category in opts[:retryable_categories] and
      (error.category != :http or error.http_status in opts[:retryable_statuses]) and
      (error.retry_eligible or error.category in [:http, :client_timeout])
  end

  defp safe_stream_failure?(%{operation: operation} = error)
       when operation in [:complete_stream, :complete_stream_events] do
    error.retry_eligible or error.category == :client_timeout
  end

  defp safe_stream_failure?(_error), do: true

  defp retry(opts, provider, operation, attempt, state) do
    with :ok <- guard_send(opts, state.deadline),
         :allow <- admission(opts, state),
         {:ok, delay} <- delay(opts, state),
         :ok <- backoff(opts, state, delay),
         :ok <- guard_send(opts, state.deadline) do
      emit(
        opts,
        :retry_started,
        Map.put(
          CompletionError.safe_metadata(state.error),
          :next_attempt,
          state.ids.wire_attempt + 1
        )
      )

      loop(opts, provider, operation, attempt, state)
    else
      reason -> terminal(opts, %{state.error | resend_permission: reason})
    end
  end

  defp admission(opts, state) do
    case opts[:admission] do
      nil ->
        decision =
          if state.error.provider == :openai or state.error.acceptance == :no,
            do: :allow,
            else: :admission_required

        type = if decision == :allow, do: :admission_allowed, else: :admission_required
        emit(opts, type, CompletionError.safe_metadata(state.error))
        decision

      callback ->
        context = %{
          failure: CompletionError.safe_metadata(state.error),
          logical_request_id: state.ids.logical_request_id,
          previous_attempt_id: state.ids.attempt_id,
          next_attempt: state.ids.wire_attempt + 1,
          progress: state.error.progress,
          reply_to: self(),
          ref: make_ref()
        }

        emit(opts, :admission_pending, context.failure)

        decision =
          opts
          |> work(state.deadline, fn -> {:admission_decision, callback.(context)} end)
          |> admission_decision()

        decision =
          if decision == :pending,
            do: await_decision(opts, state.deadline, context.ref),
            else: decision

        type =
          case decision do
            :allow -> :admission_allowed
            :admission_no_decision -> :admission_no_decision
            _ -> :admission_rejected
          end

        emit(opts, type, context.failure)

        if decision in [:allow, :cancelled, :deadline, :admission_no_decision],
          do: decision,
          else: :rejected
    end
  end

  # Tag callback returns so they cannot impersonate worker cancellation or deadline.
  # Keep shared work/3 semantics unchanged for backoff.
  defp admission_decision({:admission_decision, decision})
       when decision in [:allow, :reject, :pending],
       do: decision

  defp admission_decision(reason) when reason in [:cancelled, :deadline], do: reason
  defp admission_decision(_), do: :admission_no_decision

  defp await_decision(opts, deadline, ref) do
    cancel = opts[:cancel_ref]

    receive do
      {:recovery_admission, ^ref, decision} when decision in [:allow, :reject] -> decision
      {:cancel, ^cancel} when not is_nil(cancel) -> :cancelled
    after
      remaining(opts, deadline) ->
        case guard_send(opts, deadline) do
          :ok -> await_decision(opts, deadline, ref)
          reason -> reason
        end
    end
  end

  defp delay(opts, state) do
    ceiling = exponential(opts[:base_delay], opts[:delay_ceiling], state.ids.wire_attempt - 1)
    jitter = Keyword.get(opts, :jitter, &(:rand.uniform(&1 + 1) - 1)).(ceiling)
    minimum = state.retry_minimum
    delay = max(minimum, jitter)

    cond do
      not is_integer(jitter) or jitter < 0 or jitter > ceiling -> :invalid_jitter
      minimum > opts[:delay_ceiling] -> :retry_after_ceiling
      state.deadline != nil and delay >= state.deadline - now(opts) -> :deadline
      true -> {:ok, delay}
    end
  end

  defp exponential(base, ceiling, _n) when base >= ceiling, do: ceiling
  defp exponential(base, _ceiling, 0), do: base
  defp exponential(0, _ceiling, _n), do: 0
  defp exponential(base, ceiling, n), do: exponential(min(base * 2, ceiling), ceiling, n - 1)

  defp retry_after(_opts, {:delay_seconds, seconds}), do: seconds * 1000

  defp retry_after(opts, {:http_date, date}) do
    {:ok, date, _} = DateTime.from_iso8601(date)
    wall = Keyword.get(opts, :wall_clock, &DateTime.utc_now/0).()
    max(0, DateTime.diff(date, wall, :millisecond))
  end

  defp retry_after(_opts, _), do: 0

  defp backoff(opts, state, delay) do
    emit(
      opts,
      :backoff_started,
      Map.put(CompletionError.safe_metadata(state.error), :delay_ms, delay)
    )

    case opts[:sleeper] do
      nil ->
        wait_delay(opts, delay)

      callback ->
        case work(opts, state.deadline, fn -> callback.(delay) end) do
          result when result in [:ok, :cancelled, :deadline] -> result
          _failure -> :backoff_failed
        end
    end
  end

  defp wait_delay(opts, delay) do
    cancel = opts[:cancel_ref]

    receive do
      {:cancel, ^cancel} when not is_nil(cancel) -> :cancelled
    after
      min(delay, @max_timer_delay) ->
        if delay > @max_timer_delay, do: wait_delay(opts, delay - @max_timer_delay), else: :ok
    end
  end

  @doc false
  def request(opts, deadline, callback) when is_function(callback, 0),
    do: request(opts, deadline, {fn -> :ok end, callback})

  def request(opts, deadline, {started, callback}) do
    case guard_send(opts, deadline) do
      :ok ->
        result =
          if opts[:cancel_ref] do
            request_work(opts, deadline, started, callback)
          else
            started.()
            callback.()
          end

        case result do
          {:not_sent, _} -> result
          _ -> if(opts[:cancel_ref], do: result, else: request_result(opts, result))
        end

      reason ->
        {:not_sent, reason}
    end
  end

  defp request_result(opts, result) do
    case guard_send(opts, nil) do
      :cancelled -> {:error, :cancelled}
      :ok -> result
    end
  end

  defp request_work(opts, deadline, started, callback) do
    owner = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            case guard_send(opts, deadline) do
              :ok ->
                send(owner, {ref, :dispatch_ready})

                receive do
                  {^ref, :dispatch} -> callback.()
                end

              reason ->
                {:not_sent, reason}
            end
          rescue
            exception -> {:error, exception}
          catch
            kind, cause -> {:error, {kind, cause}}
          end

        send(owner, {ref, result})
      end)

    try do
      await_request(opts, ref, pid, monitor, started, false)
    after
      stop_work(pid, monitor, ref)
    end
  end

  defp await_request(
         opts,
         ref,
         pid,
         monitor,
         started,
         dispatched,
         progress \\ nil,
         evidence \\ nil
       ) do
    cancel = opts[:cancel_ref]

    receive do
      {:request_evidence, ^pid, received} ->
        await_request(opts, ref, pid, monitor, started, dispatched, progress, received)

      {:stream_delivery, ^pid, _updated, owner, delivery_ref} ->
        case guard_send(opts, nil) do
          :ok ->
            send(owner, {:stream_delivery_ack, delivery_ref})
            await_request(opts, ref, pid, monitor, started, dispatched, progress, evidence)

          :cancelled ->
            {:error, {:request_cancelled, evidence, progress, nil}}
        end

      {:stream_delivery_commit, ^pid, updated} ->
        await_request(opts, ref, pid, monitor, started, dispatched, updated, evidence)

      {:stream_progress, ^pid, updated} ->
        await_request(opts, ref, pid, monitor, started, dispatched, updated, evidence)

      {^ref, :dispatch_ready} ->
        # The worker's final guard has completed. Account only after the caller
        # has checked cancellation, before authorizing the HTTP boundary.
        case guard_send(opts, nil) do
          :ok ->
            started.()
            send(pid, {ref, :dispatch})
            await_request(opts, ref, pid, monitor, started, true)

          reason ->
            {:not_sent, reason}
        end

      {^ref, result} ->
        case guard_send(opts, nil) do
          :ok -> retain_capture(result, evidence, progress)
          :cancelled -> {:error, {:request_cancelled, evidence, progress, result}}
        end

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :rejected}

      {:cancel, ^cancel} ->
        cond do
          not dispatched -> {:not_sent, :cancelled}
          evidence != nil -> {:error, {:request_cancelled, evidence, progress, nil}}
          progress != nil -> {:error, {:stream_cancelled, progress}}
          true -> {:error, :cancelled}
        end
    end
  end

  defp retain_capture(
         {:error, %CompletionError{reason: :capture_failed, operation: operation} = error},
         evidence,
         progress
       )
       when not is_nil(evidence) and operation in [:complete_stream, :complete_stream_events],
       do:
         {:error, Mojentic.LLM.CompletionRequest.retain_stream_capture(error, evidence, progress)}

  defp retain_capture(result, _evidence, _progress), do: result

  defp work(opts, deadline, callback) do
    owner = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            callback.()
          rescue
            exception -> {:error, exception}
          catch
            kind, cause -> {:error, {kind, cause}}
          end

        send(owner, {ref, result})
      end)

    try do
      await_work(opts, deadline, ref, monitor)
    after
      stop_work(pid, monitor, ref)
    end
  end

  defp stop_work(pid, monitor, ref) do
    termination = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^termination, :process, ^pid, _} -> :ok
    end

    Process.demonitor(monitor, [:flush])

    receive do
      {^ref, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  defp await_work(opts, deadline, ref, monitor) do
    cancel = opts[:cancel_ref]

    receive do
      {^ref, value} -> value
      {:DOWN, ^monitor, :process, _pid, _reason} -> :rejected
      {:cancel, ^cancel} when not is_nil(cancel) -> :cancelled
    after
      remaining(opts, deadline) ->
        case guard_send(opts, deadline) do
          :ok -> await_work(opts, deadline, ref, monitor)
          reason -> reason
        end
    end
  end

  @doc false
  def cancelled?(opts), do: guard_send(opts, nil) == :cancelled

  defp guard_send(opts, deadline) do
    cancel = opts[:cancel_ref]

    receive do
      {:cancel, ^cancel} when not is_nil(cancel) -> :cancelled
    after
      0 -> if deadline != nil and now(opts) >= deadline, do: :deadline, else: :ok
    end
  end

  defp now(opts), do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end).()
  defp remaining(_opts, nil), do: :infinity
  defp remaining(opts, deadline), do: min(@max_timer_delay, max(0, deadline - now(opts)))

  defp stopped(%{error: nil} = state, provider, operation, reason) do
    {:error, error} = CompletionRequest.unsupported(provider, operation, state.ids)

    %{
      error
      | category: if(reason == :cancelled, do: :cancellation, else: :client_timeout),
        reason: reason,
        resend_permission: reason,
        private_cause: fn -> reason end
    }
  end

  defp stopped(state, _provider, _operation, reason),
    do: %{state.error | resend_permission: reason}

  defp terminal(opts, error) do
    type =
      if error.category == :cancellation or error.resend_permission == :cancelled,
        do: :cancelled,
        else: :exhausted

    emit(opts, type, CompletionError.safe_metadata(error))
    {:error, error}
  end

  defp emit(opts, type, metadata) do
    if opts[:observer], do: opts[:observer].(%{type: type, metadata: metadata})
  end
end
