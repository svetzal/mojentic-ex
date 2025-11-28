defmodule Mojentic.MixProject do
  use Mix.Project

  @version "1.0.0"
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
      docs: docs(),
      test_coverage: [
        summary: [threshold: 80],
        ignore_modules: [
          # Example modules don't need test coverage
          Mojentic.Examples.React.DecisioningAgent,
          Mojentic.Examples.React.SummarizationAgent,
          Mojentic.Examples.React.ThinkingAgent,
          Mojentic.Examples.React.ToolCallAgent,
          Mojentic.Examples.React.OutputAgent,
          Mojentic.Examples.React.Events,
          Mojentic.Examples.React.Events.FailureOccurred,
          Mojentic.Examples.React.Events.FinishAndSummarize,
          Mojentic.Examples.React.Events.InvokeDecisioning,
          Mojentic.Examples.React.Events.InvokeThinking,
          Mojentic.Examples.React.Events.InvokeToolCall,
          Mojentic.Examples.React.Models,
          Mojentic.Examples.React.Models.CurrentContext,
          Mojentic.Examples.React.Models.NextAction,
          Mojentic.Examples.React.Models.Plan,
          Mojentic.Examples.React.Models.ThoughtActionObservation,
          # OpenAI gateway not yet fully implemented
          Mojentic.LLM.Gateways.OpenAI,
          Mojentic.LLM.Gateways.OpenAIMessagesAdapter
        ]
      ]
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

      # Tokenization (Hugging Face tokenizers via Rustler NIF)
      {:tokenizers, "~> 0.4"},

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
          Mojentic.LLM.Gateways.Ollama,
          Mojentic.LLM.Gateways.TokenizerGateway
        ],
        Tools: [
          Mojentic.LLM.Tools.Tool,
          Mojentic.LLM.Tools.DateResolver,
          Mojentic.LLM.Tools.CurrentDateTime,
          Mojentic.LLM.Tools.WebSearchTool
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
