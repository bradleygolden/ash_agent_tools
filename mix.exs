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
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16", only: :test}
    ] ++ sibling_deps()
  end

  defp sibling_deps do
    if local_dev?() do
      [{:ash_agent, path: "../ash_agent"}]
    else
      [{:ash_agent, "~> 0.3"}]
    end
  end

  defp local_dev? do
    System.get_env("HEX_DEPS") != "true" and
      File.exists?(Path.expand("../ash_agent/mix.exs", __DIR__))
  end

  defp aliases do
    [
      precommit: [
        &set_hex_deps/1,
        "deps.get",
        "deps.unlock --unused",
        "compile --warnings-as-errors",
        "test --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow",
        "deps.audit",
        "dialyzer",
        "docs --warnings-as-errors",
        &unset_hex_deps/1
      ]
    ]
  end

  defp set_hex_deps(_) do
    System.put_env("HEX_DEPS", "true")
  end

  defp unset_hex_deps(_) do
    System.put_env("HEX_DEPS", "")
  end

  defp description do
    "Provider-agnostic tool calling runtime and adapters for Ash Agent."
  end

  defp package do
    [
      name: :ash_agent_tools,
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Bradley Golden"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      list_unused_filters: true
    ]
  end
end
