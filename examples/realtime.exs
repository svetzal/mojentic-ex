# Realtime Voice Example (text mode)
#
# Demonstrates a full realtime voice session against the OpenAI Realtime API
# using text-only mode (no microphone required).
#
# Requirements:
#   export OPENAI_API_KEY="sk-..."
#
# Usage:
#   mix run examples/realtime.exs
#
# The example opens a session, sends a short text message, collects the
# assistant's reply, then closes cleanly.

alias Mojentic.Realtime.{Broker, Config, OpenAIGateway, Session}
alias Mojentic.Realtime.Event

api_key =
  case System.get_env("OPENAI_API_KEY") do
    nil -> nil
    "" -> nil
    key -> key
  end

unless api_key do
  IO.puts("""
  OPENAI_API_KEY is not set.

  This example requires a live OpenAI Realtime API key.
  Set it with:

    export OPENAI_API_KEY="sk-..."

  then re-run:

    mix run examples/realtime.exs
  """)

  System.halt(1)
end

IO.puts("Connecting to OpenAI Realtime API (text mode)...")

config =
  Config.new(
    modalities: [:text],
    instructions: "You are a concise assistant. Answer in one sentence.",
    turn_detection: :none,
    input_audio_transcription: false
  )

broker =
  Broker.new("gpt-realtime-2",
    gateway: OpenAIGateway.new(api_key: api_key),
    config: config
  )

case Broker.connect(broker) do
  {:ok, session} ->
    IO.puts("Session open. Subscribing and sending message...")
    :ok = Session.subscribe(session, self())
    :ok = Session.send_text(session, "What is the capital of Japan?")

    answer =
      Stream.resource(
        fn -> "" end,
        fn acc ->
          receive do
            {:realtime_event, %Event{kind: :assistant_text_delta, payload: %{delta: d}}} ->
              {[d], acc <> d}

            {:realtime_event, %Event{kind: :assistant_turn_completed}} ->
              {:halt, acc}

            {:realtime_event, %Event{kind: :error, payload: %{error: err}}} ->
              IO.puts("Error from server: #{err}")
              {:halt, acc}

            {:realtime_event, _} ->
              {[], acc}
          after
            10_000 ->
              IO.puts("Timed out waiting for response.")
              {:halt, acc}
          end
        end,
        fn _acc -> :ok end
      )
      |> Enum.join()

    IO.puts("\nAssistant: #{answer}")
    Session.close(session)
    IO.puts("Session closed.")

  {:error, reason} ->
    IO.puts("Failed to connect: #{inspect(reason)}")
    System.halt(1)
end
