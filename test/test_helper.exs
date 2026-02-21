# Define mocks for Mojentic.HTTP
Mox.defmock(Mojentic.HTTPMock, for: Mojentic.HTTP)

# Replace HTTP client with the mock in test environment
Application.put_env(:mojentic, :http_client, Mojentic.HTTPMock)

ExUnit.start()
