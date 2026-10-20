Application.put_env(:mojentic, :internal_clock, Mojentic.TestSupport.Clock)

# Define mocks for Mojentic.HTTP
Mox.defmock(Mojentic.HTTPMock, for: Mojentic.HTTP)

# Replace HTTP client with the mock in test environment
Application.put_env(:mojentic, :http_client, Mojentic.HTTPMock)

# Session tests use the public tokenizer boundary; tokenizer operation tests
# load the committed byte-tokenizer fixture. Neither path downloads models.
Application.put_env(:mojentic, :default_tokenizer_mod, Mojentic.TestSupport.StubTokenizer)

Mox.defmock(Mojentic.TaskStreamMock, for: Mojentic.TaskStream)

ExUnit.start()

# Metadata consumers derive responses from context-window-v1, verified through the in-process Req adapter.
Mox.defmock(Mojentic.ContextWindowGatewayMock, for: Mojentic.LLM.Gateway)

Mox.defmock(Mojentic.LegacyContextWindowGatewayMock,
  for: Mojentic.LLM.Gateway,
  skip_optional_callbacks: true
)

Mox.defmock(Mojentic.MonotonicClockMock, for: Mojentic.LLM.MonotonicClock)

# Pool supervision logs do not imply socket activity: streaming ReqClient starts
# lazy Finch pools even when Req dispatch uses an in-process adapter. Observe the
# actual connection boundary across the entire suite, including fresh consumers.
connection_attempts = :atomics.new(1, [])
handler_id = {__MODULE__, :offline_connections, make_ref()}

:ok =
  :telemetry.attach(
    handler_id,
    [:finch, :connect, :start],
    fn _event, _measurements, _metadata, counter -> :atomics.add(counter, 1, 1) end,
    connection_attempts
  )

ExUnit.after_suite(fn _results ->
  :telemetry.detach(handler_id)
  attempts = :atomics.get(connection_attempts, 1)

  if attempts != 0 do
    raise "Offline test suite attempted #{attempts} Finch connection(s); use a Req test adapter"
  end

  IO.puts("Offline transport verification: zero Finch connection attempts")
end)
