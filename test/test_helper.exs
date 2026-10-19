# Define mocks for Mojentic.HTTP
Mox.defmock(Mojentic.HTTPMock, for: Mojentic.HTTP)

# Replace HTTP client with the mock in test environment
Application.put_env(:mojentic, :http_client, Mojentic.HTTPMock)

# Session tests use the public tokenizer boundary; tokenizer operation tests
# load the committed byte-tokenizer fixture. Neither path downloads models.
Application.put_env(:mojentic, :default_tokenizer_mod, Mojentic.TestSupport.StubTokenizer)

ExUnit.start()

# Metadata consumers derive responses from context-window-v1, verified through the in-process Req adapter.
Mox.defmock(Mojentic.ContextWindowGatewayMock, for: Mojentic.LLM.Gateway)

Mox.defmock(Mojentic.LegacyContextWindowGatewayMock,
  for: Mojentic.LLM.Gateway,
  skip_optional_callbacks: true
)

Mox.defmock(Mojentic.MonotonicClockMock, for: Mojentic.LLM.MonotonicClock)
