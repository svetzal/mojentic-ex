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
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
