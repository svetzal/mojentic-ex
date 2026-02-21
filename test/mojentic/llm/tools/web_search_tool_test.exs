defmodule Mojentic.LLM.Tools.WebSearchToolTest do
  use ExUnit.Case, async: true

  import Mox

  alias Mojentic.LLM.Tools.WebSearchTool

  setup :verify_on_exit!

  @sample_html """
  <html>
  <body>
  <table>
  <tr>
  <td>
  <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Felixir-lang.org%2F">Elixir Programming Language</a>
  </td>
  </tr>
  <tr>
  <td class="result-snippet">A dynamic, functional language for building scalable applications.</td>
  </tr>
  <tr>
  <td>
  <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fhexdocs.pm%2F">HexDocs - Elixir Documentation</a>
  </td>
  </tr>
  <tr>
  <td class="result-snippet">Documentation for Elixir packages and libraries.</td>
  </tr>
  <tr>
  <td>
  <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Felixirschool.com%2F">Elixir School</a>
  </td>
  </tr>
  <tr>
  <td class="result-snippet">Premier destination for learning Elixir.</td>
  </tr>
  </table>
  </body>
  </html>
  """

  @empty_html """
  <html>
  <body>
  <p>No results found</p>
  </body>
  </html>
  """

  describe "descriptor/0" do
    test "returns valid tool descriptor" do
      descriptor = WebSearchTool.descriptor()

      assert descriptor.type == "function"
      assert descriptor.function.name == "web_search"
      assert is_binary(descriptor.function.description)
      assert descriptor.function.description =~ "Search the web"
      assert descriptor.function.description =~ "DuckDuckGo"
      assert descriptor.function.parameters.type == "object"
      assert Map.has_key?(descriptor.function.parameters.properties, :query)
      assert descriptor.function.parameters.required == ["query"]
    end

    test "query parameter has correct schema" do
      descriptor = WebSearchTool.descriptor()
      query_param = descriptor.function.parameters.properties.query

      assert query_param.type == "string"
      assert is_binary(query_param.description)
    end
  end

  describe "new/1" do
    test "creates tool with default http client" do
      tool = WebSearchTool.new()

      assert %WebSearchTool{} = tool
      assert is_atom(tool.http_client)
    end

    test "creates tool with custom http client" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      assert tool.http_client == Mojentic.HTTPMock
    end
  end

  describe "run/2" do
    test "successfully searches and returns results" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn url, _headers, _opts ->
        assert url =~ "lite.duckduckgo.com/lite/"
        assert url =~ "q=Elixir"
        {:ok, %{status_code: 200, body: @sample_html}}
      end)

      assert {:ok, results} = WebSearchTool.run(tool, %{"query" => "Elixir"})

      assert is_list(results)
      assert length(results) == 3

      [first | _rest] = results

      assert first.title == "Elixir Programming Language"
      assert first.url == "https://elixir-lang.org/"
      assert first.snippet == "A dynamic, functional language for building scalable applications."
    end

    test "properly encodes query parameters" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn url, _headers, _opts ->
        assert url =~ "q=hello+world"
        {:ok, %{status_code: 200, body: @empty_html}}
      end)

      WebSearchTool.run(tool, %{"query" => "hello world"})
    end

    test "limits results to maximum" do
      # Create HTML with more than 10 results
      many_results =
        Enum.map_join(1..15, "", fn i ->
          """
          <tr>
          <td>
          <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2F#{i}">Result #{i}</a>
          </td>
          </tr>
          <tr>
          <td class="result-snippet">Snippet #{i}</td>
          </tr>
          """
        end)

      html = "<html><body><table>#{many_results}</table></body></html>"

      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: html}}
      end)

      assert {:ok, results} = WebSearchTool.run(tool, %{"query" => "test"})
      assert length(results) == 10
    end

    test "handles empty query" do
      tool = WebSearchTool.new()

      assert {:error, "Query parameter is required"} = WebSearchTool.run(tool, %{})
    end

    test "handles empty string query" do
      tool = WebSearchTool.new()

      assert {:error, "Query parameter is required"} = WebSearchTool.run(tool, %{"query" => ""})
    end

    test "handles HTTP error response" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Internal Server Error"}}
      end)

      assert {:error, error_msg} = WebSearchTool.run(tool, %{"query" => "test"})
      assert error_msg =~ "HTTP request failed with status 500"
    end

    test "handles network timeout" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:error, %{reason: :timeout}}
      end)

      assert {:error, error_msg} = WebSearchTool.run(tool, %{"query" => "test"})
      assert error_msg =~ "HTTP request failed"
    end

    test "handles connection error" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:error, :econnrefused}
      end)

      assert {:error, error_msg} = WebSearchTool.run(tool, %{"query" => "test"})
      assert error_msg =~ "HTTP request failed"
    end

    test "returns empty list when no results found" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: @empty_html}}
      end)

      assert {:ok, results} = WebSearchTool.run(tool, %{"query" => "test"})
      assert results == []
    end

    test "decodes HTML entities in titles and snippets" do
      html = """
      <html>
      <body>
      <table>
      <tr>
      <td>
      <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com">AT&amp;T &amp; Verizon</a>
      </td>
      </tr>
      <tr>
      <td class="result-snippet">Compare &quot;mobile&quot; carriers &amp; plans</td>
      </tr>
      </table>
      </body>
      </html>
      """

      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: html}}
      end)

      assert {:ok, [result]} = WebSearchTool.run(tool, %{"query" => "test"})
      assert result.title == "AT&T & Verizon"
      assert result.snippet == "Compare \"mobile\" carriers & plans"
    end

    test "handles results with missing snippets" do
      html = """
      <html>
      <body>
      <table>
      <tr>
      <td>
      <a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com">Example</a>
      </td>
      </tr>
      <tr>
      <td class="result-snippet"></td>
      </tr>
      </table>
      </body>
      </html>
      """

      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: html}}
      end)

      assert {:ok, [result]} = WebSearchTool.run(tool, %{"query" => "test"})
      assert result.title == "Example"
      assert result.url == "https://example.com"
      assert result.snippet == ""
    end

    test "handles direct URLs without redirect encoding" do
      html = """
      <html>
      <body>
      <table>
      <tr>
      <td>
      <a class="result-link" href="https://example.com">Direct Link</a>
      </td>
      </tr>
      <tr>
      <td class="result-snippet">No redirect</td>
      </tr>
      </table>
      </body>
      </html>
      """

      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: html}}
      end)

      assert {:ok, [result]} = WebSearchTool.run(tool, %{"query" => "test"})
      assert result.url == "https://example.com"
    end

    test "cleans whitespace from titles and snippets" do
      html = """
      <html>
      <body>
      <table>
      <tr>
      <td>
      <a class="result-link" href="https://example.com">  Multiple   Spaces  </a>
      </td>
      </tr>
      <tr>
      <td class="result-snippet">  Extra   whitespace   here  </td>
      </tr>
      </table>
      </body>
      </html>
      """

      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: html}}
      end)

      assert {:ok, [result]} = WebSearchTool.run(tool, %{"query" => "test"})
      assert result.title == "Multiple Spaces"
      assert result.snippet == "Extra whitespace here"
    end

    test "sets appropriate timeout for HTTP request" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, opts ->
        assert Keyword.get(opts, :timeout) == 10_000
        assert Keyword.get(opts, :recv_timeout) == 10_000
        {:ok, %{status_code: 200, body: @empty_html}}
      end)

      WebSearchTool.run(tool, %{"query" => "test"})
    end
  end

  describe "result structure" do
    test "each result has required fields" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: @sample_html}}
      end)

      assert {:ok, results} = WebSearchTool.run(tool, %{"query" => "test"})

      for result <- results do
        assert Map.has_key?(result, :title)
        assert Map.has_key?(result, :url)
        assert Map.has_key?(result, :snippet)
        assert is_binary(result.title)
        assert is_binary(result.url)
        assert is_binary(result.snippet)
      end
    end

    test "URLs are properly decoded" do
      tool = WebSearchTool.new(http_client: Mojentic.HTTPMock)

      expect(Mojentic.HTTPMock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: @sample_html}}
      end)

      assert {:ok, [first | _]} = WebSearchTool.run(tool, %{"query" => "test"})
      assert first.url == "https://elixir-lang.org/"
      refute first.url =~ "uddg="
      refute first.url =~ "%2F"
    end
  end
end
