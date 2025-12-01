defmodule AshAgentTools.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bradleygolden/ash_agent_tools"

  def project do
    [
      app: :ash_agent_tools,
      version: @version,
      elixir: "~> 1.18",
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [preferred_envs: [check: :test, precommit: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AshAgentTools.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.2"},
      {:req_llm, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16", only: :test}
    ] ++ sibling_deps()
  end

  defp sibling_deps do
    if in_umbrella?() do
      [{:ash_agent, in_umbrella: true}]
    else
      [{:ash_agent, "~> 0.3"}]
    end
  end

  defp in_umbrella? do
    # FORCE_HEX_DEPS=true bypasses umbrella detection for hex.publish
    if System.get_env("FORCE_HEX_DEPS") == "true" do
      false
    else
      parent_mix = Path.expand("../../mix.exs", __DIR__)

      File.exists?(parent_mix) and
        parent_mix |> File.read!() |> String.contains?("apps_path")
    end
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow",
        "deps.audit",
        "dialyzer",
        "docs --warnings-as-errors"
      ]
    ]
  end

  defp description do
    "Provider-agnostic tool calling runtime and adapters for Ash Agent."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      list_unused_filters: true
    ]
  end
end
