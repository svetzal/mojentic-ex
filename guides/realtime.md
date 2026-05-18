# Realtime Voice

Mojentic exposes `Mojentic.Realtime.Broker` as the entry point for
realtime voice sessions against providers that speak the OpenAI
Realtime API (the only built-in provider today is OpenAI's own).

It mirrors the Python and TypeScript ports: a long-lived broker, a
short-lived per-session GenServer that owns a WebSocket, and a
vendor-neutral event stream you subscribe to.

## 30-second example (text mode)

```elixir
alias Mojentic.Realtime.{Broker, Config, OpenAIGateway, Session}

config =
  Config.new(
    modalities: [:text],
    instructions: "You are a concise assistant.",
    turn_detection: :none,
    input_audio_transcription: false
  )

broker =
  Broker.new("gpt-realtime-2",
    gateway: OpenAIGateway.new(),
    config: config
  )

{:ok, session} = Broker.connect(broker)
:ok = Session.subscribe(session, self())
:ok = Session.send_text(session, "What's the capital of Canada?")

receive_loop = fn loop ->
  receive do
    {:realtime_event, %{kind: :assistant_text, payload: %{text: text}}} ->
      IO.puts(text)

    {:realtime_event, %{kind: :assistant_turn_completed}} ->
      :done

    {:realtime_event, _} ->
      loop.(loop)

    {:realtime_close, _} ->
      :done
  end
end

receive_loop.(receive_loop)
Session.close(session)
```

## Events

`Mojentic.Realtime.Event` is a struct with two fields: `:kind` (a
symbol drawn from a 23-element discriminated union) and `:payload`
(a map of the event's fields). Pattern match in `receive` blocks or
`case` statements.

| Group | Kinds |
|---|---|
| Session lifecycle | `:session_opened`, `:session_updated`, `:session_closed` |
| User speech | `:user_speech_started`, `:user_speech_stopped`, `:user_transcript_delta`, `:user_transcript` |
| Assistant output | `:assistant_turn_started`, `:assistant_text_delta`, `:assistant_text`, `:assistant_transcript_delta`, `:assistant_transcript`, `:assistant_audio_delta`, `:assistant_turn_completed` |
| Tool calls | `:tool_call_started`, `:tool_call_args_delta`, `:tool_call_dispatched`, `:tool_call_completed`, `:tool_call_failed`, `:tool_batch_submitted` |
| Control | `:interrupted`, `:rate_limited`, `:error` |

## Tools

Pass tools (modules or struct instances implementing the
`Mojentic.LLM.Tools.Tool` behaviour) via `Config.new(tools: [...])`.
The session dispatches them through `Mojentic.LLM.Tools.ParallelToolRunner`
by default — when the model emits multiple `function_call` items in
one turn, they execute concurrently via `Task.async_stream/3` and the
results are submitted back as `function_call_output` items before the
next `response.create` lands.

## Audio I/O

The library is **hardware-free**. Use `Session.send_audio_frame/2`
with raw PCM16 binaries and consume `:assistant_audio_delta` events
to play audio back. For a portable example, read frames from a WAV
file and write the assistant's response to another WAV file.

For live device I/O, integrate a platform audio library at the
boundary (Membrane, PortAudio, etc.); the session API stays the same.

## Interruption

The default `on_interrupt: :drop` policy discards tool outputs from
a cancelled batch so the next turn isn't polluted by stale answers.
Alternatives:

- `:submit_completed_only` — submit only outcomes that finished
  before the cancel landed (snake_case; matches the atom in code).
- `:submit` — submit every outcome, even after the cancel.

Manual interruption: `Session.interrupt(session)`.
Server-driven barge-in: the session detects
`input_audio_buffer.speech_started` mid-response and cancels
automatically.
