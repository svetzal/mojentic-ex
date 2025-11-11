defmodule Mojentic.Error do
  @moduledoc """
  Standardized error types and helpers for the Mojentic framework.

  Follows Elixir conventions of returning `{:ok, result}` or `{:error, reason}` tuples.
  Exceptions are reserved for truly exceptional situations.

  ## Error Reasons

  ### Atoms (simple errors)
  - `:invalid_response` - Response from LLM gateway could not be parsed
  - `:model_not_supported` - Requested model is not available
  - `:timeout` - Operation timed out

  ### Tagged Tuples (errors with context)
  - `{:gateway_error, message}` - LLM gateway error
  - `{:api_error, message}` - API-specific error
  - `{:http_error, status}` - HTTP request failed with status code
  - `{:request_failed, reason}` - Network request failed
  - `{:tool_error, message}` - Tool execution error
  - `{:config_error, message}` - Invalid configuration
  - `{:serialization_error, message}` - JSON serialization/deserialization error
  """

  @type simple_error ::
          :invalid_response
          | :model_not_supported
          | :timeout

  @type tagged_error ::
          {:gateway_error, String.t()}
          | {:api_error, String.t()}
          | {:http_error, integer()}
          | {:request_failed, term()}
          | {:tool_error, String.t()}
          | {:config_error, String.t()}
          | {:serialization_error, String.t()}

  @type error_reason :: simple_error() | tagged_error() | String.t()

  @type result(success_type) :: {:ok, success_type} | {:error, error_reason()}

  @doc """
  Creates a gateway error tuple.

  ## Examples

      iex> Mojentic.Error.gateway_error("Connection failed")
      {:error, {:gateway_error, "Connection failed"}}
  """
  @spec gateway_error(String.t()) :: {:error, {:gateway_error, String.t()}}
  def gateway_error(message) when is_binary(message) do
    {:error, {:gateway_error, message}}
  end

  @doc """
  Creates an API error tuple.

  ## Examples

      iex> Mojentic.Error.api_error("Rate limit exceeded")
      {:error, {:api_error, "Rate limit exceeded"}}
  """
  @spec api_error(String.t()) :: {:error, {:api_error, String.t()}}
  def api_error(message) when is_binary(message) do
    {:error, {:api_error, message}}
  end

  @doc """
  Creates an HTTP error tuple.

  ## Examples

      iex> Mojentic.Error.http_error(404)
      {:error, {:http_error, 404}}
  """
  @spec http_error(integer()) :: {:error, {:http_error, integer()}}
  def http_error(status) when is_integer(status) do
    {:error, {:http_error, status}}
  end

  @doc """
  Creates a request failed error tuple.

  ## Examples

      iex> Mojentic.Error.request_failed(:timeout)
      {:error, {:request_failed, :timeout}}
  """
  @spec request_failed(term()) :: {:error, {:request_failed, term()}}
  def request_failed(reason) do
    {:error, {:request_failed, reason}}
  end

  @doc """
  Creates a tool error tuple.

  ## Examples

      iex> Mojentic.Error.tool_error("Invalid parameters")
      {:error, {:tool_error, "Invalid parameters"}}
  """
  @spec tool_error(String.t()) :: {:error, {:tool_error, String.t()}}
  def tool_error(message) when is_binary(message) do
    {:error, {:tool_error, message}}
  end

  @doc """
  Creates a config error tuple.

  ## Examples

      iex> Mojentic.Error.config_error("Missing API key")
      {:error, {:config_error, "Missing API key"}}
  """
  @spec config_error(String.t()) :: {:error, {:config_error, String.t()}}
  def config_error(message) when is_binary(message) do
    {:error, {:config_error, message}}
  end

  @doc """
  Creates a serialization error tuple.

  ## Examples

      iex> Mojentic.Error.serialization_error("Invalid JSON")
      {:error, {:serialization_error, "Invalid JSON"}}
  """
  @spec serialization_error(String.t()) :: {:error, {:serialization_error, String.t()}}
  def serialization_error(message) when is_binary(message) do
    {:error, {:serialization_error, message}}
  end

  @doc """
  Creates an invalid response error tuple.

  ## Examples

      iex> Mojentic.Error.invalid_response()
      {:error, :invalid_response}
  """
  @spec invalid_response() :: {:error, :invalid_response}
  def invalid_response do
    {:error, :invalid_response}
  end

  @doc """
  Creates a model not supported error tuple.

  ## Examples

      iex> Mojentic.Error.model_not_supported()
      {:error, :model_not_supported}
  """
  @spec model_not_supported() :: {:error, :model_not_supported}
  def model_not_supported do
    {:error, :model_not_supported}
  end

  @doc """
  Creates a timeout error tuple.

  ## Examples

      iex> Mojentic.Error.timeout()
      {:error, :timeout}
  """
  @spec timeout() :: {:error, :timeout}
  def timeout do
    {:error, :timeout}
  end

  @doc """
  Formats an error reason into a human-readable string.

  ## Examples

      iex> Mojentic.Error.format_error({:gateway_error, "Connection failed"})
      "Gateway error: Connection failed"

      iex> Mojentic.Error.format_error(:invalid_response)
      "Invalid response"

      iex> Mojentic.Error.format_error("Custom error")
      "Custom error"
  """
  @spec format_error(error_reason()) :: String.t()
  def format_error({:gateway_error, message}), do: "Gateway error: #{message}"
  def format_error({:api_error, message}), do: "API error: #{message}"
  def format_error({:http_error, status}), do: "HTTP error: #{status}"
  def format_error({:request_failed, reason}), do: "Request failed: #{inspect(reason)}"
  def format_error({:tool_error, message}), do: "Tool error: #{message}"
  def format_error({:config_error, message}), do: "Configuration error: #{message}"
  def format_error({:serialization_error, message}), do: "Serialization error: #{message}"
  def format_error(:invalid_response), do: "Invalid response"
  def format_error(:model_not_supported), do: "Model not supported"
  def format_error(:timeout), do: "Timeout"
  def format_error(message) when is_binary(message), do: message
  def format_error(other), do: "Unknown error: #{inspect(other)}"
end
