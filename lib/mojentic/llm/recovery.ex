defmodule Mojentic.LLM.Recovery do
  @moduledoc """
  Bounded, opt-in recovery of a single immutable non-streaming completion.

  Admission receives safe failure metadata, correlation IDs, progress, and a
  `reply_to` PID and `ref`. Return `:allow`, `:reject`, or `:pending`; resolve
  pending decisions with `{:recovery_admission, ref, :allow | :reject}`.
  Send `{:cancel, cancel_ref}` to the completion caller to cancel locally.
  Local HTTP cancellation never proves remote inference termination.
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

  @doc "Capabilities implemented by this non-streaming adapter boundary."
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

    if valid?(opts) do
      policy = Keyword.merge(@defaults, opts)
      state = %{ids: ids, history: [], deadline: policy[:deadline], error: nil, retry_minimum: 0}
      loop(policy, provider, operation, attempt, state)
    else
      CompletionRequest.unsupported(provider, operation, ids)
    end
  end

  defp valid?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and Enum.all?(opts, &valid_option?/1)
  end

  defp valid?(_), do: false
  defp valid_option?({:max_attempts, n}), do: is_integer(n) and n > 0

  defp valid_option?({key, n}) when key in [:base_delay, :delay_ceiling, :budget],
    do: is_integer(n) and n >= 0

  defp valid_option?({:deadline, n}), do: is_integer(n)

  defp valid_option?({key, callback}) when key in [:observer, :admission, :jitter, :sleeper],
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
    error.category in opts[:retryable_categories] and
      (error.category != :http or error.http_status in opts[:retryable_statuses]) and
      (error.retry_eligible or error.category in [:http, :client_timeout])
  end

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
        decision = work(opts, state.deadline, fn -> callback.(context) end)

        decision =
          if decision == :pending,
            do: await_decision(opts, state.deadline, context.ref),
            else: decision

        type = if decision == :allow, do: :admission_allowed, else: :admission_rejected
        emit(opts, type, context.failure)
        if decision in [:allow, :cancelled, :deadline], do: decision, else: :rejected
    end
  end

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
  def request(opts, deadline, callback) do
    case guard_send(opts, deadline) do
      :ok ->
        result =
          if opts[:cancel_ref],
            do:
              work(opts, nil, fn ->
                case guard_send(opts, deadline) do
                  :ok -> callback.()
                  reason -> {:not_sent, reason}
                end
              end),
            else: callback.()

        case guard_send(opts, nil) do
          :cancelled -> {:error, :cancelled}
          :ok -> request_result(result)
        end

      reason ->
        {:not_sent, reason}
    end
  end

  defp request_result(:cancelled), do: {:error, :cancelled}
  defp request_result(result), do: result

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
