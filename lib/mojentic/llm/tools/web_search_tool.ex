defmodule Mojentic.LLM.Tools.WebSearchTool do
  @moduledoc """
  Tool for searching the web using DuckDuckGo.

  This tool searches DuckDuckGo's lite endpoint and returns organic search results.
  It does not require an API key, making it a free alternative to paid search APIs.

  ## Examples

      alias Mojentic.LLM.Tools.WebSearchTool

      tool = WebSearchTool.new()
      {:ok, results} = WebSearchTool.run(tool, %{"query" => "Elixir programming"})
      # => {:ok, [%{title: "...", url: "...", snippet: "..."}]}

  ## Configuration

  You can optionally configure the HTTP client for testing:

      tool = WebSearchTool.new(http_client: MyHTTPClient)

  """

  @behaviour Mojentic.LLM.Tools.Tool

  defstruct http_client: nil

  @base_url "https://lite.duckduckgo.com/lite/"
  @max_results 10
  @timeout 10_000

  @doc """
  Creates a new WebSearchTool instance.

  ## Options

  - `:http_client` - Optional HTTP client module for testing (defaults to configured client)
  """
  def new(opts \\ []) do
    %__MODULE__{
      http_client: Keyword.get(opts, :http_client, http_client())
    }
  end

  @impl true
  def run(%__MODULE__{http_client: client}, arguments) do
    query = Map.get(arguments, "query")

    if is_nil(query) or query == "" do
      {:error, "Query parameter is required"}
    else
      perform_search(client, query)
    end
  end

  @impl true
  def descriptor do
    %{
      type: "function",
      function: %{
        name: "web_search",
        description:
          "Search the web for information using DuckDuckGo. Returns organic search results including title, URL, and snippet for each result.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "The search query"
            }
          },
          required: ["query"]
        }
      }
    }
  end

  # Private functions

  defp http_client do
    Application.get_env(:mojentic, :http_client, Mojentic.HTTP.ReqClient)
  end

  defp perform_search(client, query) do
    url = build_url(query)

    case client.get(url, [], timeout: @timeout, recv_timeout: @timeout) do
      {:ok, %{status_code: 200, body: body}} ->
        parse_results(body)

      {:ok, %{status_code: status_code}} ->
        {:error, "HTTP request failed with status #{status_code}"}

      {:error, %{reason: reason}} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp build_url(query) do
    encoded_query = URI.encode_www_form(query)
    "#{@base_url}?q=#{encoded_query}"
  end

  defp parse_results(html) do
    results =
      html
      |> extract_results()
      |> Enum.take(@max_results)

    {:ok, results}
  end

  defp extract_results(html) do
    # DuckDuckGo lite uses a simple structure:
    # Results are in table rows with class "result-link"
    # Each result has:
    # - <a class="result-link" href="url">Title</a>
    # - <td class="result-snippet">Snippet text</td>

    # Split by result links
    html
    |> String.split(~r/<a[^>]+class="result-link"/, include_captures: false)
    |> Enum.drop(1)
    |> Enum.map(&parse_result_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_result_block(block) do
    with {:ok, url} <- extract_url(block),
         {:ok, title} <- extract_title(block),
         {:ok, snippet} <- extract_snippet(block) do
      %{
        title: clean_text(title),
        url: url,
        snippet: clean_text(snippet)
      }
    else
      _ -> nil
    end
  end

  defp extract_url(block) do
    case Regex.run(~r/href="([^"]+)"/, block) do
      [_, url] -> {:ok, decode_url(url)}
      _ -> :error
    end
  end

  defp extract_title(block) do
    case Regex.run(~r/href="[^"]+">([^<]+)<\/a>/, block) do
      [_, title] -> {:ok, title}
      _ -> :error
    end
  end

  defp extract_snippet(block) do
    # Snippet is in a td with class result-snippet
    case Regex.run(~r/<td class="result-snippet">([^<]*)</, block) do
      [_, snippet] -> {:ok, snippet}
      _ -> {:ok, ""}
    end
  end

  defp decode_url(url) do
    # DuckDuckGo uses redirect URLs like //duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com
    case Regex.run(~r/uddg=([^&]+)/, url) do
      [_, encoded_url] -> URI.decode_www_form(encoded_url)
      _ -> url
    end
  end

  defp clean_text(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> decode_html_entities()
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
