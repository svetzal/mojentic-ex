defmodule Mojentic.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/svetzal/mojentic-ex"

  def project do
    [
      app: :mojentic,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "An LLM integration framework for Elixir",
      package: package(),
      name: "Mojentic",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # HTTP client
      {:httpoison, "~> 2.0"},

      # JSON
      {:jason, "~> 1.4"},

      # UUID generation
      {:elixir_uuid, "~> 1.2"},

      # Development and testing
      {:mox, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # AI Assistant
      {:igniter, "~> 0.7", only: [:dev]},
      {:usage_rules, "~> 0.1", only: [:dev]}
    ]
  end

  defp package do
    [
      maintainers: ["Stacey Vetzal"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md)
    ]
  end

  defp docs do
    [
      main: "introduction",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md": [title: "Overview"],
        "guides/introduction.md": [title: "Introduction"],
        "guides/getting_started.md": [title: "Getting Started"],
        "guides/broker.md": [title: "Broker Guide"],
        "guides/tool_usage.md": [title: "Tool Usage"],
        "guides/structured_output.md": [title: "Structured Output"],
        "AGENTS.md": [title: "AI Assistant Guidelines"]
      ],
      groups_for_extras: [
        Guides: ~r/guides\//,
        "Project Info": ["README.md", "AGENTS.md"]
      ],
      groups_for_modules: [
        Core: [
          Mojentic,
          Mojentic.Error
        ],
        "LLM Integration": [
          Mojentic.LLM.Broker,
          Mojentic.LLM.Gateway,
          Mojentic.LLM.GatewayResponse,
          Mojentic.LLM.Message,
          Mojentic.LLM.ToolCall,
          Mojentic.LLM.CompletionConfig
        ],
        Gateways: [
          Mojentic.LLM.Gateways.Ollama
        ],
        Tools: [
          Mojentic.LLM.Tools.Tool,
          Mojentic.LLM.Tools.DateResolver,
          Mojentic.LLM.Tools.CurrentDateTime
        ]
      ],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10.2.0/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({ startOnLoad: false });
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""
end
