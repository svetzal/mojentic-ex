defmodule Mojentic.Realtime.Session do
  @moduledoc """
  Stateful realtime session handle, owning a transport process.

  Implemented as a GenServer that:

  - subscribes to a transport (typically a `MintTransport` pid)
  - receives raw OpenAI realtime events, normalises them into
    vendor-neutral `Mojentic.Realtime.Event` values, and forwards
    each to subscribers
  - tracks per-turn state and dispatches `function_call` items as
    a batch via the configured `Mojentic.LLM.Tools.Runner`
  - submits `function_call_output` items back through the transport
    and triggers the next `response.create`

  ## Tool batch execution

  When `response.done` arrives with pending function calls, the
  session spawns a supervised `Task` to run the batch so the GenServer
  remains responsive to inbound WebSocket messages (e.g.
  `input_audio_buffer.speech_started` barge-in) during execution.
  The task sends `{:tool_batch_done, executions, outcomes, duration_ms}`
  back to the session when it completes.

  An `:atomics`-backed cancel ref is stored in the `RunContext` so
  calling `interrupt/1` mid-batch signals cancellation to any tool
  that has opted in via `run/3`.

  This module mirrors the RealtimeSession class in the Python port.
  The broker uses it to provide a single ergonomic entry point.
  """

  use GenServer

  alias Mojentic.LLM.Tools.ParallelToolRunner
  alias Mojentic.LLM.Tools.RunContext
  alias Mojentic.LLM.Tools.ToolCallExecution
  alias Mojentic.Realtime.Codec
  alias Mojentic.Realtime.Config
  alias Mojentic.Realtime.Event
  alias Mojentic.Realtime.SemanticVadConfig
  alias Mojentic.Realtime.ServerVadConfig

  @type t :: pid()

  defstruct transport: nil,
            transport_module: nil,
            config: nil,
            tools: [],
            tool_runner: ParallelToolRunner,
            tracer: nil,
            correlation_id: nil,
            subscribers: [],
            current_turn: nil,
            current_response_id: nil,
            batch_task: nil,
            batch_cancel_ref: nil,
            closed?: false

  # Public API ----------------------------------------------------------------

  @doc """
  Start a session linked to the calling process.

  Required opts:
  - `:transport` — pid of an established transport
  - `:transport_module` — module implementing the Transport behaviour
  - `:config` — Mojentic.Realtime.Config struct
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Subscribe to vendor-neutral events. The subscriber receives `{:realtime_event, %Event{}}`."
  def subscribe(pid, subscriber \\ self()) do
    GenServer.call(pid, {:subscribe, subscriber})
  end

  @doc "Send the initial `session.update` derived from the config. Called by the broker."
  def initialise(pid) do
    GenServer.call(pid, :initialise)
  end

  @doc "Send a text-mode user message and request a response."
  def send_text(pid, text) when is_binary(text) do
    GenServer.call(pid, {:send_text, text})
  end

  @doc "Manually commit the input audio buffer (push-to-talk mode)."
  def commit_audio(pid) do
    GenServer.call(pid, :commit_audio)
  end

  @doc "Append a PCM16 binary frame to the server's audio buffer."
  def send_audio_frame(pid, frame) when is_binary(frame) do
    GenServer.call(pid, {:send_audio_frame, frame})
  end

  @doc "Manually cancel the in-flight assistant response."
  def interrupt(pid) do
    GenServer.call(pid, :interrupt)
  end

  @doc "Update instructions for future assistant turns."
  def update_instructions(pid, instructions) when is_binary(instructions) do
    GenServer.call(pid, {:update_instructions, instructions})
  end

  @doc "Close the session and underlying transport."
  def close(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
  end

  # GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    transport_module = Keyword.fetch!(opts, :transport_module)
    config = Keyword.fetch!(opts, :config)

    state = %__MODULE__{
      transport: transport,
      transport_module: transport_module,
      config: config,
      tools: config.tools || [],
      tool_runner: Keyword.get(opts, :tool_runner, ParallelToolRunner),
      tracer: Keyword.get(opts, :tracer),
      correlation_id: Keyword.get(opts, :correlation_id, UUID.uuid4()),
      subscribers: []
    }

    # The transport is already alive; we listen for messages forwarded to us.
    transport_module.subscribe(transport, self())

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscribers: [subscriber | state.subscribers]}}
  end

  @impl true
  def handle_call(:initialise, _from, state) do
    payload = build_session_update(state.config)
    reply = state.transport_module.send(state.transport, payload)
    emit(state, Event.new(:session_opened, %{session_id: inspect(self())}))
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:send_text, text}, _from, state) do
    with :ok <-
           state.transport_module.send(state.transport, %{
             "type" => "conversation.item.create",
             "item" => %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => text}]
             }
           }),
         :ok <- state.transport_module.send(state.transport, %{"type" => "response.create"}) do
      {:reply, :ok, state}
    else
      err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:send_audio_frame, frame}, _from, state) do
    payload = %{
      "type" => "input_audio_buffer.append",
      "audio" => Codec.encode_base64_pcm16(frame)
    }

    {:reply, state.transport_module.send(state.transport, payload), state}
  end

  @impl true
  def handle_call(:commit_audio, _from, state) do
    with :ok <-
           state.transport_module.send(state.transport, %{"type" => "input_audio_buffer.commit"}),
         :ok <- state.transport_module.send(state.transport, %{"type" => "response.create"}) do
      {:reply, :ok, state}
    else
      err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:interrupt, _from, state) do
    state = cancel_current_turn(state, :manual)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_instructions, instructions}, _from, state) do
    payload = %{"type" => "session.update", "session" => %{"instructions" => instructions}}
    new_config = %{state.config | instructions: instructions}
    {:reply, state.transport_module.send(state.transport, payload), %{state | config: new_config}}
  end

  @impl true
  def handle_info({:realtime_message, msg}, state) do
    {:noreply, handle_server_event(msg, state)}
  end

  def handle_info({:realtime_close, _reason}, state) do
    emit(state, Event.new(:session_closed, %{reason: :server}))
    {:stop, :normal, %{state | closed?: true}}
  end

  def handle_info({:realtime_error, reason}, state) do
    emit(state, Event.new(:error, %{error: reason, recoverable?: true}))
    {:noreply, state}
  end

  # Per-tool-call observability events from the RunContext callbacks.
  # These are sent from Task workers back to the session so we can
  # forward them to subscribers without blocking the batch.
  def handle_info({:emit_event, %Event{} = event}, state) do
    emit(state, event)
    {:noreply, state}
  end

  # Tool batch completed asynchronously — submit outputs and clear turn.
  def handle_info({:tool_batch_done, executions, outcomes, duration_ms}, state) do
    record_batch(state, executions, outcomes, duration_ms)
    new_state = submit_outcomes(state, outcomes)
    {:noreply, %{new_state | batch_task: nil, batch_cancel_ref: nil}}
  end

  # Task exit messages from the supervised tool-batch task.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{batch_task: %Task{pid: pid}} = state) do
    {:noreply, %{state | batch_task: nil, batch_cancel_ref: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.transport_module && state.transport && Process.alive?(state.transport) do
      state.transport_module.close(state.transport)
    end

    emit(state, Event.new(:session_closed, %{reason: :client}))
    :ok
  end

  # Event handlers ------------------------------------------------------------

  defp handle_server_event(%{"type" => "session.created"}, state), do: state

  defp handle_server_event(%{"type" => "session.updated"}, state) do
    emit(state, Event.new(:session_updated, %{instructions: state.config.instructions}))
    state
  end

  defp handle_server_event(%{"type" => "input_audio_buffer.speech_started"} = msg, state) do
    emit(state, Event.new(:user_speech_started, %{at_ms: msg["audio_start_ms"]}))

    if state.current_turn && not state.current_turn.cancelled? do
      cancel_current_turn(state, :barge_in)
    else
      state
    end
  end

  defp handle_server_event(%{"type" => "input_audio_buffer.speech_stopped"} = msg, state) do
    emit(state, Event.new(:user_speech_stopped, %{at_ms: msg["audio_end_ms"]}))
    state
  end

  defp handle_server_event(
         %{"type" => "conversation.item.input_audio_transcription.delta"} = msg,
         state
       ) do
    emit(
      state,
      Event.new(:user_transcript_delta, %{item_id: msg["item_id"], delta: msg["delta"]})
    )

    state
  end

  defp handle_server_event(
         %{"type" => "conversation.item.input_audio_transcription.completed"} = msg,
         state
       ) do
    emit(state, Event.new(:user_transcript, %{item_id: msg["item_id"], text: msg["transcript"]}))
    state
  end

  defp handle_server_event(%{"type" => "response.created", "response" => %{"id" => id}}, state) do
    emit(state, Event.new(:assistant_turn_started, %{turn_id: id}))
    %{state | current_response_id: id, current_turn: new_turn(id)}
  end

  defp handle_server_event(%{"type" => "response.output_item.added", "item" => item}, state) do
    case item do
      %{"type" => "function_call", "call_id" => call_id, "name" => name} ->
        emit(
          state,
          Event.new(:tool_call_started, %{turn_id: turn_id(state), call_id: call_id, name: name})
        )

        put_in_turn(state, [:calls, call_id], %{
          call_id: call_id,
          name: name,
          args_buffer: "",
          done?: false
        })

      _ ->
        state
    end
  end

  defp handle_server_event(
         %{"type" => "response.function_call_arguments.delta"} = msg,
         state
       ) do
    call_id = msg["call_id"]
    delta = msg["delta"]
    emit(state, Event.new(:tool_call_args_delta, %{call_id: call_id, delta: delta}))

    update_turn_call(state, call_id, fn c ->
      %{c | args_buffer: c.args_buffer <> delta}
    end)
  end

  defp handle_server_event(
         %{"type" => "response.function_call_arguments.done"} = msg,
         state
       ) do
    update_turn_call(state, msg["call_id"], fn c ->
      %{c | args_buffer: msg["arguments"] || c.args_buffer, done?: true}
    end)
  end

  defp handle_server_event(%{"type" => type, "delta" => delta} = _msg, state)
       when type in ["response.text.delta", "response.output_text.delta"] do
    emit(state, Event.new(:assistant_text_delta, %{turn_id: turn_id(state), delta: delta}))
    state
  end

  defp handle_server_event(%{"type" => type, "text" => text}, state)
       when type in ["response.text.done", "response.output_text.done"] do
    emit(state, Event.new(:assistant_text, %{turn_id: turn_id(state), text: text}))
    state
  end

  defp handle_server_event(%{"type" => type, "delta" => delta}, state)
       when type in [
              "response.audio_transcript.delta",
              "response.output_audio_transcript.delta"
            ] do
    emit(state, Event.new(:assistant_transcript_delta, %{turn_id: turn_id(state), delta: delta}))
    state
  end

  defp handle_server_event(%{"type" => type, "transcript" => text}, state)
       when type in [
              "response.audio_transcript.done",
              "response.output_audio_transcript.done"
            ] do
    emit(state, Event.new(:assistant_transcript, %{turn_id: turn_id(state), text: text}))
    state
  end

  defp handle_server_event(%{"type" => type, "delta" => delta}, state)
       when type in ["response.audio.delta", "response.output_audio.delta"] do
    pcm = Codec.decode_base64_pcm16(delta)
    emit(state, Event.new(:assistant_audio_delta, %{turn_id: turn_id(state), pcm: pcm}))
    state
  end

  defp handle_server_event(%{"type" => "response.done", "response" => response}, state) do
    handle_response_done(response, state)
  end

  defp handle_server_event(%{"type" => "rate_limits.updated"} = msg, state) do
    reset_ms =
      case msg["rate_limits"] do
        [%{} = first | _] -> Map.get(first, "reset_seconds", 0) * 1000
        _ -> 0
      end

    emit(
      state,
      Event.new(:rate_limited, %{reset_ms: trunc(reset_ms), details: msg["rate_limits"]})
    )

    state
  end

  defp handle_server_event(%{"type" => "error", "error" => err}, state) do
    message = Map.get(err, "message", "unknown realtime error")

    if String.contains?(String.downcase(message), "no active response") do
      state
    else
      emit(
        state,
        Event.new(:error, %{
          error: message,
          recoverable?: Map.get(err, "type") != "session_error"
        })
      )

      state
    end
  end

  defp handle_server_event(_other, state), do: state

  # Response-done / tool batch -----------------------------------------------

  defp handle_response_done(
         %{"id" => id} = _response,
         %{current_turn: %{turn_id: id} = turn} = state
       ) do
    emit(state, Event.new(:assistant_turn_completed, %{turn_id: id}))

    case Map.values(turn.calls) do
      [] ->
        %{state | current_turn: nil, current_response_id: nil}

      calls ->
        start_tool_batch_async(calls, %{state | current_turn: %{turn | done?: true}})
    end
  end

  defp handle_response_done(_response, state),
    do: %{state | current_turn: nil, current_response_id: nil}

  # Spawn the tool batch in a monitored Task so the GenServer stays
  # responsive to barge-in and other inbound messages while tools run.
  defp start_tool_batch_async(calls, state) do
    {executions, parse_failures} = parse_executions(calls)
    Enum.each(parse_failures, &emit(state, &1))

    if executions == [] do
      %{state | current_turn: nil, current_response_id: nil}
    else
      cancel_ref = :atomics.new(1, signed: false)
      ctx = build_run_context(state, cancel_ref)
      session_pid = self()

      task =
        Task.async(fn ->
          start_time = System.monotonic_time(:millisecond)
          outcomes = state.tool_runner.run_batch(executions, state.tools, ctx)
          duration_ms = System.monotonic_time(:millisecond) - start_time
          send(session_pid, {:tool_batch_done, executions, outcomes, duration_ms})
        end)

      %{state | batch_task: task, batch_cancel_ref: cancel_ref}
    end
  end

  defp parse_executions(calls) do
    Enum.reduce(calls, {[], []}, fn call, {execs, fails} ->
      case Jason.decode(call.args_buffer || "") do
        {:ok, args} when is_map(args) ->
          {[ToolCallExecution.new(call.call_id, call.name, args) | execs], fails}

        {:ok, _other} ->
          {[ToolCallExecution.new(call.call_id, call.name, %{}) | execs], fails}

        {:error, _} ->
          ev =
            Event.new(:tool_call_failed, %{
              call_id: call.call_id,
              name: call.name,
              error: :invalid_arguments
            })

          {execs, [ev | fails]}
      end
    end)
    |> then(fn {execs, fails} -> {Enum.reverse(execs), Enum.reverse(fails)} end)
  end

  defp build_run_context(state, cancel_ref) do
    self_pid = self()

    RunContext.new(
      correlation_id: state.correlation_id,
      source: "RealtimeSession",
      cancel_ref: cancel_ref,
      on_call_start: fn call ->
        send(
          self_pid,
          {:emit_event,
           Event.new(:tool_call_dispatched, %{call_id: call.id, name: call.name, args: call.args})}
        )

        :ok
      end,
      on_call_complete: fn outcome ->
        send(self_pid, {:emit_event, outcome_event(outcome)})
        :ok
      end
    )
  end

  defp outcome_event(%{ok?: true} = o) do
    Event.new(:tool_call_completed, %{call_id: o.id, name: o.name, result: o.result})
  end

  defp outcome_event(%{ok?: false} = o) do
    Event.new(:tool_call_failed, %{call_id: o.id, name: o.name, error: o.error})
  end

  defp record_batch(_state, [], _outcomes, _duration), do: :ok

  defp record_batch(state, executions, outcomes, duration_ms) do
    success = Enum.count(outcomes, & &1.ok?)
    failure = length(outcomes) - success

    if state.tracer do
      Mojentic.Tracer.record_tool_batch(state.tracer,
        batch_id: UUID.uuid4(),
        tool_names: Enum.map(executions, & &1.name),
        success_count: success,
        failure_count: failure,
        call_duration_ms: duration_ms,
        caller: "RealtimeSession",
        source: __MODULE__,
        correlation_id: state.correlation_id
      )
    end
  end

  defp submit_outcomes(state, outcomes) do
    policy = state.config.on_interrupt || Config.defaults().on_interrupt
    to_submit = select_outputs(state, outcomes, policy)

    submitted_ids =
      for outcome <- to_submit do
        payload = %{
          "type" => "conversation.item.create",
          "item" => %{
            "type" => "function_call_output",
            "call_id" => outcome.id,
            "output" => serialise_output(outcome)
          }
        }

        state.transport_module.send(state.transport, payload)
        outcome.id
      end

    if submitted_ids != [] do
      emit(
        state,
        Event.new(:tool_batch_submitted, %{turn_id: turn_id(state), call_ids: submitted_ids})
      )

      state.transport_module.send(state.transport, %{"type" => "response.create"})
    end

    %{state | current_turn: nil, current_response_id: nil}
  end

  defp select_outputs(%{current_turn: %{cancelled?: true}}, _outcomes, :drop), do: []

  defp select_outputs(%{current_turn: %{cancelled?: true}}, outcomes, :submit_completed_only),
    do: Enum.filter(outcomes, & &1.ok?)

  defp select_outputs(_state, outcomes, _policy), do: outcomes

  defp serialise_output(%{ok?: true, result: result}), do: Jason.encode!(result)

  defp serialise_output(%{ok?: false, error: error}),
    do: Jason.encode!(%{"error" => inspect(error)})

  # Helpers -------------------------------------------------------------------

  defp emit(%{subscribers: subs}, %Event{} = event) do
    Enum.each(subs, fn pid -> Process.send(pid, {:realtime_event, event}, []) end)
  end

  defp emit(_state, _event), do: :ok

  defp cancel_current_turn(%{current_turn: nil} = state, _reason), do: state
  defp cancel_current_turn(%{current_turn: %{cancelled?: true}} = state, _reason), do: state

  defp cancel_current_turn(state, reason) do
    turn = %{state.current_turn | cancelled?: true}
    emit(state, Event.new(:interrupted, %{turn_id: turn.turn_id, reason: reason}))

    if state.current_response_id do
      state.transport_module.send(state.transport, %{"type" => "response.cancel"})
    end

    # Signal any in-flight tool batch to abort early.
    if state.batch_cancel_ref do
      RunContext.cancel(%RunContext{cancel_ref: state.batch_cancel_ref})
    end

    %{state | current_turn: turn}
  end

  defp new_turn(turn_id) do
    %{turn_id: turn_id, calls: %{}, cancelled?: false, done?: false}
  end

  defp turn_id(%{current_turn: %{turn_id: id}}), do: id
  defp turn_id(_), do: nil

  defp put_in_turn(state, [:calls, key], value) do
    turn = state.current_turn || new_turn(state.current_response_id || "unknown")
    %{state | current_turn: %{turn | calls: Map.put(turn.calls, key, value)}}
  end

  defp update_turn_call(%{current_turn: nil} = state, _call_id, _fun), do: state

  defp update_turn_call(state, call_id, fun) do
    turn = state.current_turn

    case Map.get(turn.calls, call_id) do
      nil -> state
      call -> %{state | current_turn: %{turn | calls: Map.put(turn.calls, call_id, fun.(call))}}
    end
  end

  # session.update builder ----------------------------------------------------

  @doc """
  Build the vendor-specific ``session.update`` payload from a
  vendor-neutral config. Mirrors the GA shape used by mojentic-py /
  mojentic-ts: ``session.type: 'realtime'``, output modalities, audio
  input/output blocks, etc.
  """
  def build_session_update(%Config{} = config) do
    defaults = Config.defaults()
    modalities = config.modalities || defaults.modalities
    output_modalities = if :audio in modalities, do: ["audio"], else: ["text"]

    audio_input = %{
      "format" => encode_audio_format(config.input_audio_format || defaults.input_audio_format),
      "turn_detection" => encode_turn_detection(config.turn_detection || defaults.turn_detection)
    }

    audio_input =
      case config.input_audio_transcription do
        false -> Map.put(audio_input, "transcription", nil)
        %{} = t -> Map.put(audio_input, "transcription", t)
        _ -> audio_input
      end

    audio_output =
      %{
        "format" =>
          encode_audio_format(config.output_audio_format || defaults.output_audio_format)
      }
      |> maybe_put("voice", config.voice)

    session =
      %{
        "type" => "realtime",
        "output_modalities" => output_modalities,
        "audio" => %{"input" => audio_input, "output" => audio_output},
        "tool_choice" => encode_tool_choice(config.tool_choice || defaults.tool_choice)
      }
      |> maybe_put("instructions", config.instructions)
      |> maybe_put("max_output_tokens", config.max_response_output_tokens)
      |> maybe_put_tools(config.tools)
      |> maybe_merge(config.provider_extras)

    %{"type" => "session.update", "session" => session}
  end

  defp encode_audio_format(:pcm16), do: %{"type" => "audio/pcm", "rate" => 24_000}
  defp encode_audio_format(:g711_ulaw), do: %{"type" => "audio/pcmu"}
  defp encode_audio_format(:g711_alaw), do: %{"type" => "audio/pcma"}

  defp encode_turn_detection(:none), do: nil
  defp encode_turn_detection(:server_vad), do: %{"type" => "server_vad"}
  defp encode_turn_detection(:semantic_vad), do: %{"type" => "semantic_vad"}

  defp encode_turn_detection(%ServerVadConfig{} = vad) do
    %{
      "type" => "server_vad",
      "threshold" => vad.threshold,
      "prefix_padding_ms" => vad.prefix_padding_ms,
      "silence_duration_ms" => vad.silence_duration_ms,
      "create_response" => vad.create_response,
      "interrupt_response" => vad.interrupt_response,
      "idle_timeout_ms" => vad.idle_timeout_ms
    }
    |> drop_nil_values()
  end

  defp encode_turn_detection(%SemanticVadConfig{} = vad) do
    %{
      "type" => "semantic_vad",
      "eagerness" => vad.eagerness,
      "create_response" => vad.create_response,
      "interrupt_response" => vad.interrupt_response
    }
    |> drop_nil_values()
  end

  defp encode_tool_choice(:auto), do: "auto"
  defp encode_tool_choice(:none), do: "none"
  defp encode_tool_choice(:required), do: "required"
  defp encode_tool_choice(%{name: name}), do: %{"type" => "function", "name" => name}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tools(map, nil), do: map
  defp maybe_put_tools(map, []), do: map

  defp maybe_put_tools(map, tools) do
    encoded =
      Enum.map(tools, fn tool ->
        descriptor = Mojentic.LLM.Tools.Tool.descriptor(tool)
        function = descriptor["function"] || descriptor[:function]

        %{
          "type" => "function",
          "name" => function["name"] || function[:name],
          "description" => function["description"] || function[:description],
          "parameters" => function["parameters"] || function[:parameters]
        }
      end)

    Map.put(map, "tools", encoded)
  end

  defp maybe_merge(map, nil), do: map
  defp maybe_merge(map, extras) when is_map(extras), do: Map.merge(map, extras)

  defp drop_nil_values(map) do
    map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
  end
end
