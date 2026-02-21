defmodule Mojentic.HTTP do
  @moduledoc """
  Behaviour for HTTP clients used by Mojentic gateways.

  This behaviour abstracts the HTTP client, allowing different
  implementations for production and testing.
  """

  @type headers :: [{String.t(), String.t()}]
  @type response :: %{status_code: integer(), body: String.t(), headers: headers()}

  @callback get(url :: String.t(), headers :: headers(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @callback post(url :: String.t(), body :: String.t(), headers :: headers(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}

  @callback post_stream(
              url :: String.t(),
              body :: String.t(),
              headers :: headers(),
              opts :: keyword()
            ) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
