defmodule Mojentic.LLM.StreamRecovery do
  @moduledoc false

  alias Mojentic.LLM.{CompletionError, CompletionRequest, Recovery, StreamTiming, ToolCall}
  alias Mojentic.LLM.Gateways.{Ollama, OllamaStream, OpenAIStream}

  # One local worker owns every HTTP continuation for this logical request.
  # Demand is acknowledged before another semantic event can be delivered.
  def stream(client, url, body, headers, opts, recovery, provider, mode) do
    if Recovery.valid_options?(recovery) do
      Stream.resource(
        fn -> open(client, url, body, headers, opts, recovery, provider, mode) end,
        &next/1,
        &close/1
      )
    else
      [Recovery.run(recovery, provider, operation(mode), fn _, _ -> :unreachable end)]
    end
  end

  defp open(client, url, body, headers, opts, recovery, provider, mode) do
    timing = StreamTiming.new(provider)
    owner = self()
    ref = make_ref()
    cancel = Keyword.get(recovery, :cancel_ref, make_ref())
    recovery = Keyword.put(recovery, :cancel_ref, cancel)

    opts =
      Keyword.merge(opts,
        stream_timing: timing,
        stream_timeout: :idle,
        stream_metadata: true,
        recovery_metadata: true,
        cancel_ref: cancel
      )

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        watch_owner(owner)

        result =
          Recovery.run(recovery, provider, operation(mode), fn ids, deadline ->
            initial = %{
              owner: owner,
              ref: ref,
              ids: ids,
              outbound: {body, headers},
              recovery: recovery,
              provider: provider,
              mode: mode,
              parser: parser(provider),
              parser_state: parser(provider).new(),
              evidence: %{},
              buffer: "",
              tools: %{},
              finished: false,
              frame_index: 0,
              progress: progress(),
              status: nil,
              headers: [],
              tracker: self()
            }

            attempt = fn ->
              attempt(
                client,
                url,
                body,
                headers,
                Keyword.merge(opts,
                  wire_trace: CompletionRequest.trace(recovery, ids),
                  evidence_mode: {provider, mode},
                  received_observer: fn evidence ->
                    send(initial.tracker, {:request_evidence, self(), evidence})
                  end
                ),
                initial
              )
            end

            started = fn ->
              emit(recovery, :attempt_started, Map.put(ids, :progress, progress()))
            end

            case Recovery.request(recovery, deadline, {started, attempt}) do
              {:error, {:request_cancelled, evidence, progress, original}} ->
                CompletionRequest.cancelled(
                  evidence,
                  progress,
                  original,
                  provider,
                  operation(mode),
                  ids,
                  {body, headers}
                )

              {:error, {:stream_cancelled, progress}} ->
                failure(:cancelled, Map.merge(initial, progress))

              {:error, :cancelled} ->
                failure(:cancelled, initial)

              {:ok, {progress, _evidence}} = result ->
                emit(recovery, :attempt_succeeded, Map.put(ids, :progress, progress))
                result

              result ->
                result
            end
          end)

        result =
          case result do
            {:ok, {progress, evidence}} ->
              {:ok, {progress, StreamTiming.evidence(evidence, timing)}}

            {:error, %CompletionError{} = error} ->
              {:error, StreamTiming.error(error, timing)}

            other ->
              other
          end

        case result do
          {:ok, {_progress, evidence}} -> send(owner, {ref, :terminal, evidence})
          _ -> :ok
        end

        send(owner, {ref, :result, result})
      end)

    %{
      pid: pid,
      monitor: monitor,
      ref: ref,
      cancel: cancel,
      done: false,
      cancelling: false,
      terminal_committed: false
    }
  end

  defp watch_owner(owner) do
    worker = self()

    spawn_link(fn ->
      owner_monitor = Process.monitor(owner)
      worker_monitor = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_monitor, :process, _, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_monitor, :process, _, _} -> :ok
      end
    end)
  end

  defp operation(:events), do: :complete_stream_events
  defp operation(:legacy), do: :complete_stream
  defp parser(:ollama), do: OllamaStream
  defp parser(_), do: OpenAIStream

  defp next(%{done: true} = state), do: {:halt, state}

  defp next(state) do
    cancel = state.cancel

    receive do
      {:cancel, ^cancel} when not state.terminal_committed ->
        send(state.pid, {:cancel, cancel})
        await(%{state | cancelling: true})
    after
      0 -> await(state)
    end
  end

  defp await(state) do
    %{ref: ref, monitor: monitor, cancel: cancel} = state

    receive do
      {^ref, :event, _event, _worker, _progress} when state.cancelling ->
        await(state)

      {^ref, :need_demand, _worker} when state.cancelling ->
        await(state)

      {^ref, :need_demand, worker} ->
        send(worker, {ref, :demand})
        await(state)

      {^ref, :event, event, worker, progress} ->
        acknowledge_delivery(state, event, worker, progress)

      {^ref, :terminal, evidence} ->
        {[{:completed, evidence}], %{state | done: true}}

      {^ref, :result, {:ok, _}} ->
        {:halt, %{state | done: true}}

      {^ref, :result, {:error, error}} ->
        {[{:error, error}], %{state | done: true}}

      {:cancel, ^cancel} when not state.terminal_committed ->
        send(state.pid, {:cancel, cancel})
        await(%{state | cancelling: true})

      {:cancel, ^cancel} ->
        await(state)

      {:DOWN, ^monitor, :process, _, _} ->
        {[{:error, :stream_worker_failed}], %{state | done: true}}
    end
  end

  defp acknowledge_delivery(state, event, worker, progress) do
    delivery_ref = make_ref()
    ref = state.ref
    monitor = state.monitor
    send(state.pid, {:stream_delivery, worker, progress, self(), delivery_ref})

    receive do
      {:stream_delivery_ack, ^delivery_ref} ->
        cancel = state.cancel

        receive do
          {:cancel, ^cancel} ->
            send(state.pid, {:cancel, cancel})
            await(%{state | cancelling: true})
        after
          0 ->
            send(state.pid, {:stream_delivery_commit, worker, progress})
            send(worker, {ref, :delivered})

            if event == :terminal,
              do: await(%{state | terminal_committed: true}),
              else: {[event], state}
        end

      {:cancel, cancel} when cancel == state.cancel ->
        send(state.pid, {:cancel, cancel})
        await(%{state | cancelling: true})

      {^ref, :result, {:error, error}} ->
        {[{:error, error}], %{state | done: true}}

      {:DOWN, ^monitor, :process, _, _} ->
        {[{:error, :stream_worker_failed}], %{state | done: true}}
    end
  end

  defp close(state) do
    unless state.done, do: send(state.pid, {:cancel, state.cancel})
    ref = state.ref
    monitor = state.monitor

    receive do
      {^ref, :result, _} -> :ok
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      1000 -> :ok
    end

    monitor = Process.monitor(state.pid)
    Process.exit(state.pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    end

    Process.demonitor(state.monitor, [:flush])
  end

  defp attempt(client, url, body, headers, opts, initial) do
    Process.link(initial.tracker)
    consume(client.post_stream(url, body, headers, opts), initial)
  rescue
    _exception in Mojentic.HTTP.WireTrace.CaptureError -> failure(:capture_failed, initial)
    exception -> failure(exception, initial)
  end

  defp consume({:error, reason}, state), do: failure(reason, state)

  defp consume({:ok, stream}, state) do
    continuation = &Enumerable.reduce(stream, &1, fn item, _ -> {:suspend, item} end)
    drive(continuation, state)
  end

  defp drive(continuation, state) do
    case continuation.({:cont, nil}) do
      {:suspended, item, rest} ->
        case safe_item(item, state) do
          {:continue, updated} ->
            drive(rest, updated)

          result ->
            halt_wire(rest, result, state)
        end

      {done, _} when done in [:done, :halted] ->
        authorize_success(finish(state), state)
    end
  rescue
    _exception in Mojentic.HTTP.WireTrace.CaptureError ->
      failure(:capture_failed, state)

    exception ->
      continuation.({:halt, nil})
      failure({:parser_failure, exception}, state)
  end

  defp halt_wire(rest, result, state) do
    rest.({:halt, nil})
    authorize_success(result, state)
  rescue
    _exception in Mojentic.HTTP.WireTrace.CaptureError ->
      progress =
        case result do
          {:ok, {progress, _}} -> progress
          {:error, error} -> error.progress
        end

      failure(:capture_failed, %{state | progress: progress})
  end

  # Final capture/cleanup completes before consumer acceptance. A paused consumer
  # leaves this attempt cancellable; after acceptance its terminal result is committed.
  defp authorize_success({:ok, {progress, _evidence}} = result, state) do
    yield(:terminal, %{state | progress: progress}, progress)
    result
  end

  defp authorize_success(result, _state), do: result

  defp finish(%{provider: :ollama, buffer: buffer} = state) when buffer != "" do
    {frames, state} = frames("\n", state)

    case parse_frames(nil, frames, state) do
      {:ok, events, state} ->
        case deliver(events, state) do
          {:continue, state} -> failure(:incomplete_stream, state)
          result -> result
        end

      {:parser_error, exception, state} ->
        failure({:parser_failure, exception}, state)
    end
  end

  defp finish(state), do: failure(:incomplete_stream, state)

  defp finish_events(_frames, %{mode: :events} = state) do
    safely(state, fn ->
      {events, _evidence} = state.parser.finish(state.parser_state)
      {:ok, events, state}
    end)
  end

  defp safe_item({:data, chunk}, state) do
    state = %{
      state
      | progress: %{state.progress | raw_bytes: state.progress.raw_bytes + byte_size(chunk)}
    }

    item({:data, chunk}, state)
  end

  defp safe_item(item, state) do
    item(item, state)
  rescue
    exception -> failure({:parser_failure, exception}, state)
  end

  defp item({:headers, status, headers}, state) do
    state = %{
      state
      | status: status,
        headers: headers,
        progress: %{state.progress | headers_received: true}
    }

    send(state.tracker, {:stream_progress, self(), snapshot(state)})
    {:continue, state}
  end

  defp item({:http_data, chunk}, state) do
    state = %{
      state
      | progress: %{state.progress | raw_bytes: state.progress.raw_bytes + byte_size(chunk)}
    }

    send(state.tracker, {:stream_progress, self(), snapshot(state)})
    {:continue, state}
  end

  defp item({:error, reason}, state), do: failure(reason, state)

  defp item({:data, chunk}, state) do
    {frames, state} = frames(chunk, state)

    case parse_frames(chunk, frames, state) do
      {:ok, events, state} ->
        send(state.tracker, {:stream_progress, self(), snapshot(state)})
        deliver(events, state)

      {:parser_error, exception, state} ->
        failure({:parser_failure, exception}, state)
    end
  rescue
    exception -> failure({:parser_failure, exception}, state)
  end

  # Validate Ollama frames before emitting metadata or accepting their semantics.
  # Each wire attempt starts a fresh parser and frame index.
  defp parse_frames(_chunk, frames, %{provider: :ollama} = state) do
    Enum.reduce_while(frames, {:ok, [], state}, fn frame, {:ok, events, current} ->
      cond do
        Map.has_key?(frame, "error") ->
          {:halt, {:ok, events ++ [{:error, {:provider_error, frame["error"]}}], current}}

        OllamaStream.valid_recovery_frame?(frame) and valid_terminal_tools?(frame, current) ->
          case safely(current, fn -> ollama_frame(frame, current) end) do
            {:ok, new_events, updated} ->
              combined = events ++ new_events

              if Enum.any?(new_events, fn {kind, _} -> kind == :error end),
                do: {:halt, {:ok, reject_semantics(combined, new_events), updated}},
                else: {:cont, {:ok, combined, updated}}

            error ->
              {:halt, error}
          end

        true ->
          observed =
            case safely(current, fn -> {:ok, observe(frame, current)} end) do
              {:ok, updated} -> updated
              _ -> current
            end

          {:halt, {:ok, reject_chunk(events ++ [{:error, :invalid_stream_event}]), observed}}
      end
    end)
  end

  # Raw bytes have already been counted. oMLX's complete data lines are filtered
  # before either observation or parsing, while partial lines remain buffered.
  defp parse_frames(chunk, frames, %{provider: :omlx} = state) do
    filtered = if is_nil(chunk), do: nil, else: state.filtered_chunk
    parse_compatible_frames(filtered, frames, state)
  end

  defp parse_frames(chunk, frames, state), do: parse_compatible_frames(chunk, frames, state)

  defp parse_compatible_frames(chunk, frames, %{mode: :events} = state) do
    with {:ok, state} <- observe_frames(frames, state) do
      if is_nil(chunk), do: finish_events(frames, state), else: parse(chunk, frames, state)
    end
  end

  defp parse_compatible_frames(chunk, frames, state), do: parse(chunk, frames, state)

  defp valid_terminal_tools?(%{"done" => false}, _state), do: true

  defp valid_terminal_tools?(frame, state) do
    candidate = accumulate(message(frame)["tool_calls"] || [], state)
    calls = complete_tools(candidate.tools)

    map_size(candidate.tools) == length(calls) and
      Enum.all?(calls, fn call -> byte_size(call.name) > 0 end)
  end

  defp reject_semantics(events, frame_events) do
    if Enum.any?(frame_events, fn
         {:error, {:incomplete_completion, _}} -> true
         _ -> false
       end),
       do: events,
       else: reject_chunk(events)
  end

  defp reject_chunk(events),
    do: Enum.filter(events, fn {kind, _} -> kind in [:progress, :metrics, :error] end)

  defp ollama_frame(frame, state) do
    state = observe(frame, %{state | frame_index: state.frame_index + 1})
    # Parse evidence without semantic output: a rejected final frame cannot leak
    # content or complete a tool, but its validated provider counters survive.
    encoded = Jason.encode!(Map.put(frame, "message", %{})) <> "\n"
    {terminal, parser_state} = OllamaStream.parse(state.parser_state, encoded)
    state = %{state | parser_state: parser_state}
    metadata = ollama_telemetry(frame, state)

    if frame["done"] and frame["done_reason"] != "stop" do
      {:ok, metadata ++ terminal, state}
    else
      case state.mode do
        :events ->
          content = message(frame)["content"]
          semantics = if present?(content), do: [{:content, content}], else: []
          calls = message(frame)["tool_calls"] || []

          if calls == [],
            do: {:ok, metadata ++ semantics ++ terminal, state},
            else: {:ok, metadata ++ [{:error, :unexpected_tool_calls}], state}

        :legacy ->
          {:ok, semantics, state} = parse_frame(frame, [], state)
          semantics = Enum.reject(semantics, fn {kind, _} -> kind == :completed end)
          {:ok, metadata ++ semantics ++ terminal, state}
      end
    end
  end

  defp ollama_telemetry(frame, state) do
    delta = message(frame)
    identity = Map.put(state.ids, :frame_index, state.frame_index)

    progress =
      Map.merge(identity, %{
        content_bytes: byte_size(delta["content"] || ""),
        reasoning_bytes: byte_size(delta["thinking"] || ""),
        tool_fragments: length(delta["tool_calls"] || []),
        done: frame["done"]
      })

    fields = Map.merge(Ollama.reported_usage(frame) || %{}, Ollama.reported_timings(frame) || %{})

    metrics =
      Map.new(fields, fn {key, value} ->
        {Map.fetch!(
           %{
             "prompt_eval_count" => :prompt_eval_count,
             "eval_count" => :eval_count,
             "total_duration" => :total_duration,
             "load_duration" => :load_duration,
             "prompt_eval_duration" => :prompt_eval_duration,
             "eval_duration" => :eval_duration
           },
           key
         ), value}
      end)

    metrics = if map_size(metrics) == 0, do: [], else: [{:metrics, Map.merge(identity, metrics)}]
    [{:progress, progress} | metrics]
  end

  # Rescue at the frame boundary so observations from earlier frames survive.
  # Parsing a chunk is atomic for delivery: an exception yields none of its events.
  defp observe_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, current} ->
      case safely(current, fn -> {:ok, observe(frame, current)} end) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  defp safely(state, fun) do
    fun.()
  rescue
    exception -> {:parser_error, exception, state}
  end

  defp frames(chunk, %{provider: :omlx} = state) do
    {lines, [buffer]} = String.split(state.buffer <> chunk, "\n") |> Enum.split(-1)
    lines = Enum.reject(lines, &omlx_keepalive_line?/1)
    filtered_chunk = Enum.map_join(lines, &(&1 <> "\n"))
    state = Map.put(%{state | buffer: buffer}, :filtered_chunk, filtered_chunk)
    {decode_frames(lines), state}
  end

  defp frames(chunk, state) do
    {lines, [buffer]} = String.split(state.buffer <> chunk, "\n") |> Enum.split(-1)
    {decode_frames(lines), %{state | buffer: buffer}}
  end

  defp decode_frames(lines) do
    Enum.flat_map(lines, fn line ->
      line = String.trim(line)

      data =
        if String.starts_with?(line, "data: "),
          do: String.replace_prefix(line, "data: ", ""),
          else: line

      case Jason.decode(data) do
        {:ok, object} when is_map(object) -> [object]
        _ -> invalid_frame(data)
      end
    end)
  end

  defp omlx_keepalive_line?("data:" <> data),
    do: match?({:ok, %{"model" => "keepalive"}}, Jason.decode(data))

  defp omlx_keepalive_line?(_line), do: false

  defp invalid_frame("[DONE]"), do: [%{"_done" => true}]
  defp invalid_frame(""), do: []
  defp invalid_frame(":" <> _comment), do: []
  defp invalid_frame(_), do: [%{"_invalid" => true}]

  defp message(%{"message" => message}), do: message
  defp message(%{"choices" => [%{"delta" => delta} | _]}), do: delta
  defp message(_), do: %{}

  defp observe(frame, state) do
    delta = message(frame)
    calls = delta["tool_calls"] || []
    observed = state.progress.observed

    observed = %{
      observed
      | content: observed.content or present?(delta["content"]),
        reasoning:
          observed.reasoning or present?(delta["thinking"] || delta["reasoning_content"]),
        tool_fragments:
          observed.tool_fragments + length(calls) +
            if(StreamTiming.legacy_argument_fragment?(delta), do: 1, else: 0)
    }

    %{state | progress: %{state.progress | observed: observed}}
  end

  defp parse(chunk, _frames, %{mode: :events} = state) do
    send(state.tracker, {:stream_progress, self(), snapshot(state)})

    safely(state, fn ->
      {events, parser_state} = state.parser.parse(state.parser_state, chunk)
      {:ok, events, %{state | parser_state: parser_state}}
    end)
  end

  # Observe and assemble each legacy frame before advancing, retaining completed
  # calls if a later observation fails without delivering any events from the chunk.
  defp parse(_chunk, frames, state) do
    send(state.tracker, {:stream_progress, self(), snapshot(state)})

    Enum.reduce_while(frames, {:ok, [], state}, fn frame, {:ok, events, current} ->
      with {:ok, observed} <- safely(current, fn -> {:ok, observe(frame, current)} end),
           {:ok, _, _} = parsed <-
             safely(observed, fn -> parse_frame(frame, events, observed) end) do
        {:cont, parsed}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp parse_frame(%{"choices" => [%{"finish_reason" => "length"} | _]}, events, state) do
    {:ok, events ++ [{:error, {:incomplete_completion, "length"}}], state}
  end

  defp parse_frame(frame, events, state) do
    evidence =
      Map.new(
        [
          {:usage, frame["usage"]},
          {:provider_model, frame["model"]},
          {:finish_reason, get_in(frame, ["choices", Access.at(0), "finish_reason"])}
        ]
        |> Enum.reject(fn {_, value} -> is_nil(value) end)
      )

    state = %{state | evidence: Map.merge(state.evidence, evidence)}
    delta = message(frame)
    content = if present?(delta["content"]), do: [{:content, delta["content"]}], else: []
    reasoning = delta["thinking"] || delta["reasoning_content"]
    thinking = if present?(reasoning), do: [{:thinking, reasoning}], else: []
    state = accumulate(delta["tool_calls"] || [], state)
    reason = get_in(frame, ["choices", Access.at(0), "finish_reason"])
    done = frame["done"] == true or reason in ["stop", "tool_calls"]
    calls = if done, do: complete_tools(state.tools), else: []
    tools = if calls == [], do: [], else: [{:tool_calls, calls}]

    observed = %{
      state.progress.observed
      | completed_tool_calls: state.progress.observed.completed_tool_calls + length(calls)
    }

    state = %{
      state
      | finished: done or state.finished,
        progress: %{state.progress | observed: observed}
    }

    terminal = legacy_terminal(frame, state, done, calls)

    {:ok, events ++ thinking ++ content ++ tools ++ terminal, state}
  end

  defp legacy_terminal(frame, state, done, calls) do
    cond do
      frame["_invalid"] == true ->
        [{:error, :invalid_stream_event}]

      frame["error"] != nil ->
        [{:error, {:provider_error, frame["error"]}}]

      done and map_size(state.tools) != length(calls) ->
        [{:error, :invalid_stream_event}]

      frame["_done"] == true and not state.finished ->
        [{:error, :invalid_stream_event}]

      frame["_done"] == true or (state.provider == :ollama and done) ->
        [{:completed, state.evidence}]

      true ->
        []
    end
  end

  defp accumulate(calls, state) do
    tools =
      Enum.reduce(Enum.with_index(calls), state.tools, fn {call, index}, tools ->
        key = call["index"] || index
        old = Map.get(tools, key, %{id: nil, name: nil, arguments: ""})
        function = call["function"] || %{}
        arguments = function["arguments"] || ""

        arguments =
          if is_map(arguments), do: Jason.encode!(arguments), else: old.arguments <> arguments

        Map.put(tools, key, %{
          id: call["id"] || old.id,
          name: function["name"] || old.name,
          arguments: arguments
        })
      end)

    %{state | tools: tools}
  end

  defp complete_tools(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_, tool} ->
      case Jason.decode(tool.arguments) do
        {:ok, arguments} when is_map(arguments) and is_binary(tool.name) ->
          [%ToolCall{id: tool.id, name: tool.name, arguments: arguments}]

        _ ->
          []
      end
    end)
  end

  defp deliver([], state), do: {:continue, state}
  defp deliver([{:error, reason} | _], state), do: failure(reason, state)

  defp deliver([{:completed, evidence} | _], state) do
    {:ok, {state.progress, evidence}}
  end

  defp deliver([event | rest], state) do
    delivered = state.progress.delivered

    delivered =
      case event do
        {:content, text} ->
          %{delivered | content: delivered.content or present?(text)}

        {:thinking, text} ->
          %{delivered | reasoning: delivered.reasoning or present?(text)}

        {:tool_calls, calls} ->
          %{delivered | completed_tool_calls: delivered.completed_tool_calls + length(calls)}

        {kind, _metadata} when kind in [:progress, :metrics] ->
          delivered
      end

    progress = %{state.progress | delivered: delivered}
    yield(event, state, progress)
    deliver(rest, %{state | progress: progress})
  end

  defp yield(event, state, delivered_progress) do
    send(state.tracker, {:stream_progress, self(), snapshot(state)})
    send(state.owner, {state.ref, :need_demand, self()})

    receive do
      {ref, :demand} when ref == state.ref -> :ok
    end

    send(
      state.owner,
      {state.ref, :event, event, self(), snapshot(state, delivered_progress)}
    )

    receive do
      {ref, :delivered} when ref == state.ref -> :ok
    end
  end

  defp failure(reason, state) do
    response =
      case reason do
        {:http_response, status, headers, body, _cause} ->
          {:ok, %{status_code: status, headers: headers, body: body}}

        {:http_response, status, headers, body} ->
          {:ok, %{status_code: status, headers: headers, body: body}}

        {:http_response, status, headers} ->
          {:ok, %{status_code: status, headers: headers, body: ""}}

        _ ->
          {:error, reason}
      end

    response =
      case response do
        {:error, %Finch.TransportError{source: source}} -> {:error, source}
        response -> response
      end

    error =
      CompletionRequest.build(
        response,
        failure_cause(reason),
        state.provider,
        operation(state.mode),
        state.ids,
        state.outbound,
        state.recovery
      )

    error = response_metadata(error, reason, state)

    interrupted = semantic?(state.progress.observed)

    progress =
      if http_response?(reason),
        do: %{state.progress | headers_received: true},
        else: state.progress

    error =
      case reason do
        :timeout ->
          %{error | category: :client_timeout, reason: :timeout, retry_eligible: false}

        {:provider_error, _} ->
          %{error | category: :provider_response, reason: :provider_error, retry_eligible: false}

        _ ->
          error
      end

    error =
      if protocol_failure?(reason),
        do: %{error | category: :protocol, reason: :invalid_stream, retry_eligible: false},
        else: error

    error = %{
      error
      | progress: progress,
        phase: if(state.progress.headers_received, do: :streaming, else: error.phase),
        reason: capture_reason(reason, interrupted, error.reason),
        retry_eligible: error.retry_eligible and not interrupted
    }

    {:error, %{error | history: [Map.delete(CompletionError.safe_metadata(error), :history)]}}
  end

  defp failure_cause({:http_response, _status, _headers, _body, cause}), do: cause
  defp failure_cause(reason), do: reason

  defp http_response?({:http_response, _, _}), do: true
  defp http_response?({:http_response, _, _, _}), do: true
  defp http_response?({:http_response, _, _, _, _}), do: true
  defp http_response?(_), do: false

  defp capture_reason(:capture_failed, _interrupted, _reason), do: :capture_failed
  defp capture_reason(_cause, true, _reason), do: :stream_interrupted
  defp capture_reason(_cause, false, reason), do: reason

  defp semantic?(progress) do
    progress.content or progress.reasoning or progress.tool_fragments > 0 or
      progress.completed_tool_calls > 0
  end

  defp snapshot(state, progress \\ nil),
    do: %{progress: progress || state.progress, status: state.status, headers: state.headers}

  defp response_metadata(error, reason, %{status: status} = state) when not is_nil(status) do
    body =
      case reason do
        {:http_response, _, _, body, _} -> body
        {:http_response, _, _, body} -> body
        {:provider_error, provider_error} -> Jason.encode!(%{"error" => provider_error})
        _ -> ""
      end

    metadata =
      CompletionRequest.build(
        {:ok, %{status_code: status, headers: state.headers, body: body}},
        reason,
        state.provider,
        operation(state.mode),
        state.ids,
        state.outbound,
        state.recovery
      )

    %{
      error
      | http_status: status,
        provider_request_id: metadata.provider_request_id,
        provider_code: metadata.provider_code,
        retry_after: metadata.retry_after,
        private_evidence: metadata.private_evidence
    }
  end

  defp response_metadata(error, _reason, _state), do: error

  defp protocol_failure?(reason)
       when reason in [
              :incomplete_stream,
              :invalid_stream_event,
              :invalid_stream_content,
              :unexpected_tool_calls
            ],
       do: true

  defp protocol_failure?({:incomplete_completion, _}), do: true
  defp protocol_failure?({:parser_failure, _}), do: true
  defp protocol_failure?(_), do: false

  defp present?(value), do: is_binary(value) and byte_size(value) > 0

  defp progress do
    semantic = %{content: false, reasoning: false, tool_fragments: 0, completed_tool_calls: 0}
    %{headers_received: false, raw_bytes: 0, observed: semantic, delivered: semantic}
  end

  defp emit(opts, type, metadata) do
    if opts[:observer], do: opts[:observer].(%{type: type, metadata: metadata})
  end
end
