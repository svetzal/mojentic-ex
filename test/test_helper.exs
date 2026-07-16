# Define mocks for Mojentic.HTTP
Mox.defmock(Mojentic.HTTPMock, for: Mojentic.HTTP)

# Replace HTTP client with the mock in test environment
Application.put_env(:mojentic, :http_client, Mojentic.HTTPMock)

# Use the lightweight stub tokenizer as the default in tests so that
# ChatSession tests do not trigger HuggingFace model downloads.
# Tests that specifically exercise TokenizerGateway are tagged :integration
# and excluded from the default suite — run them with: mix test --include integration
Application.put_env(:mojentic, :default_tokenizer_mod, Mojentic.TestSupport.StubTokenizer)

ExUnit.configure(exclude: [:integration])
ExUnit.start()
