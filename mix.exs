defmodule ExMaude.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/futhr/ex_maude"

  def project do
    [
      app: :ex_maude,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ExMaude",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      # C-Node compilation (conditional - only if c_src exists and erl_interface available)
      compilers: maybe_add_make_compiler(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_cwd: "c_src",
      make_error_message: """
      C-Node compilation skipped or failed. This is optional - the Port backend works without it.

      For C-Node support, ensure erl_interface is available:
        erl -noshell -eval 'io:format("~p~n", [code:lib_dir(erl_interface)]), halt().'

      On macOS with Homebrew: brew reinstall erlang
      On Debian/Ubuntu: apt install erlang-dev
      On Fedora/RHEL: dnf install erlang-devel
      """
    ]
  end

  # Only add elixir_make compiler if c_src exists and erl_interface is available
  defp maybe_add_make_compiler do
    if File.dir?("c_src") and erl_interface_available?() do
      [:elixir_make] ++ Mix.compilers()
    else
      Mix.compilers()
    end
  end

  defp erl_interface_available? do
    case System.cmd(
           "erl",
           ["-noshell", "-eval", "code:lib_dir(erl_interface), halt()."],
           stderr_to_stdout: true
         ) do
      {output, 0} -> not String.contains?(output, "error")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {ExMaude.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        cover: :test,
        "cover.html": :test,
        "test.network": :test,
        "test.integration": :test,
        "test.cnode": :test,
        "test.nif": :test,
        "test.all": :test
      ]
    ]
  end

  defp deps do
    [
      {:poolboy, "~> 1.5"},
      {:nimble_parsec, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},
      # Native code compilation
      {:elixir_make, "~> 0.8", runtime: false},
      {:rustler, "~> 0.34", runtime: false, optional: true},
      # Development tools
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:castore, "~> 1.0", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:benchee_markdown, "~> 0.3", only: :dev, runtime: false},
      {:git_ops, "~> 2.6", only: :dev, runtime: false},
      {:doctest_formatter, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description, do: "Elixir bindings for the Maude formal verification system."

  defp package do
    [
      name: "ex_maude",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Maude" => "https://maude.cs.illinois.edu"},
      files:
        ~w(lib priv/maude .formatter.exs mix.exs README.md LICENSE CHANGELOG.md usage-rules.md bench/output),
      maintainers: ["Tobias Bohwalli <hi@futhr.io>"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "notebooks/quickstart.livemd": [title: "Quick Start"],
        "notebooks/advanced.livemd": [title: "Advanced Usage"],
        "notebooks/rewriting.livemd": [title: "Term Rewriting"],
        "notebooks/benchmarks.livemd": [title: "Benchmarks"],
        "CHANGELOG.md": [title: "Changelog"],
        "CONTRIBUTING.md": [title: "Contributing"],
        "AGENTS.md": [title: "AI Agents"],
        "usage-rules.md": [title: "Usage Rules"],
        "bench/output/benchmarks.md": [title: "Benchmark Results"],
        "bench/output/backend_comparison.md": [title: "Backend Comparison"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        "Getting Started": ~r/README/,
        "Interactive Tutorials": ~r/notebooks\//,
        Reference: ~r/CHANGELOG|CONTRIBUTING|AGENTS|usage-rules|LICENSE/,
        Performance: ~r/bench\/output/
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :missing_return, :underspecs]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.compile"],
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      cover: ["coveralls"],
      "cover.html": ["coveralls.html"],
      "test.network": ["test --include network"],
      "test.integration": ["test --include integration"],
      "test.nif": ["test --include nif_integration"],
      "test.all": [
        "test --include network --include integration --include cnode_integration --include nif_integration"
      ],
      ci: ["setup", "lint", "cover"],
      # Benchmarks
      bench: ["run bench/run.exs"],
      # Port backend only
      "bench.backends": ["run bench/backends_bench.exs"],
      # All backends (requires C-Node)
      "bench.backends.all": ["cmd ./bin/bench_backends_all.sh"],
      "bench.all": ["bench", "bench.backends"],
      # C-Node specific tests (requires distribution)
      # C-Node integration tests
      "test.cnode": ["cmd ./bin/test_cnode.sh"]
    ]
  end
end
