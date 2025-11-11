# Define mocks for HTTPoison
Mox.defmock(HTTPoisonMock, for: HTTPoison.Base)

# Replace HTTPoison with the mock in test environment
Application.put_env(:mojentic, :http_client, HTTPoisonMock)

ExUnit.start()
