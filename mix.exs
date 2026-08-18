defmodule ExMaude.MixProject do
  use Mix.Project

  @version "0.3.0"
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

  # Only add elixir_make compiler if c_src exists, erl_interface is available,
  # and the binary actually needs (re)building
  defp maybe_add_make_compiler do
    if File.dir?("c_src") and erl_interface_available?() and needs_compilation?() do
      [:elixir_make] ++ Mix.compilers()
    else
      Mix.compilers()
    end
  end

  defp needs_compilation? do
    binary = "priv/maude_bridge"

    not File.exists?(binary) or
      Enum.any?(Path.wildcard("c_src/*.c") ++ Path.wildcard("c_src/*.h"), fn src ->
        File.stat!(src).mtime > File.stat!(binary).mtime
      end)
  end

  defp erl_interface_available? do
    case System.cmd(
           "erl",
           [
             "-noshell",
             "-eval",
             "case code:lib_dir(erl_interface) of {error, _} -> halt(1); _ -> halt(0) end."
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        cover: :test,
        "cover.html": :test,
        "test.cover": :test,
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
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},
      # Native code compilation
      {:elixir_make, "~> 0.8", runtime: false},
      # NIF — precompiled binaries downloaded at install time
      {:rustler_precompiled, "~> 0.8"},
      # Rustler only needed when force-building from source
      {:rustler, "~> 0.38", optional: true},
      # Development tools
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
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
      files: ~w[
        lib
        c_src/maude_bridge.c
        c_src/Makefile
        c_src/.clang-format
        c_src/.clang-tidy
        native/ex_maude_nif/src
        native/ex_maude_nif/Cargo.toml
        native/ex_maude_nif/Cargo.lock
        native/ex_maude_nif/.cargo
        checksum-Elixir.ExMaude.Backend.NIF.Native.exs
        priv/maude/iot-rules.maude
        priv/maude/ai-rules.maude
        priv/maude/VERSION
        .formatter.exs
        mix.exs
        README.md
        CONTRIBUTING.md
        LICENSE
        THIRD_PARTY_NOTICES.md
        CHANGELOG.md
        usage-rules.md
        notebooks
        cheatsheets
        bench/output
      ],
      maintainers: ["Tobias Bohwalli <hi@futhr.io>"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md": [title: "Overview"],
        "cheatsheets/cheatsheet.cheatmd": [title: "Cheatsheet"],
        "notebooks/quickstart.livemd": [title: "Quick Start"],
        "notebooks/rewriting.livemd": [title: "Term Rewriting"],
        "notebooks/advanced.livemd": [title: "Advanced Usage"],
        "notebooks/ai-rules.livemd": [title: "AI Rules"],
        "notebooks/benchmarks.livemd": [title: "Benchmarks"],
        "CHANGELOG.md": [title: "Changelog"],
        "CONTRIBUTING.md": [title: "Contributing"],
        "usage-rules.md": [title: "Usage Rules"],
        "THIRD_PARTY_NOTICES.md": [title: "Third-party Notices"],
        "bench/output/benchmarks.md": [title: "Benchmark Results"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        "Getting Started": ~r/README|cheatsheet/,
        "Interactive Tutorials": ~r/notebooks\//,
        Reference: ~r/CHANGELOG|CONTRIBUTING|usage-rules|LICENSE|THIRD_PARTY/,
        Performance: ~r/bench\/output/
      ],
      groups_for_modules: [
        "Core API": [ExMaude, ExMaude.Maude, ExMaude.Term, ExMaude.Parser],
        Results: [ExMaude.Result.Reduction, ExMaude.Result.Search, ExMaude.Result.Solution],
        "Domain: IoT": [
          ExMaude.IoT,
          ExMaude.IoT.Encoder,
          ExMaude.IoT.Validator,
          ExMaude.IoT.ConflictParser
        ],
        "Domain: AI": [
          ExMaude.AI,
          ExMaude.AI.Encoder,
          ExMaude.AI.Validator,
          ExMaude.AI.ConflictParser
        ],
        Runtime: [
          ExMaude.Pool,
          ExMaude.Server,
          ExMaude.Backend,
          ExMaude.Backend.Port,
          ExMaude.Backend.CNode,
          ExMaude.Backend.NIF,
          ExMaude.Binary,
          ExMaude.Config
        ],
        Observability: [ExMaude.Telemetry],
        Errors: [ExMaude.Error]
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
      "test.cover": ["coveralls"],
      "test.network": ["test --include network"],
      "test.integration": ["test --include integration"],
      "test.nif": [&test_nif/1],
      "test.all": [
        "test --include network --include integration --include cnode --include nif"
      ],
      ci: ["setup", "lint", "cover"],
      # Benchmarks
      bench: ["run bench/run.exs"],
      # Every backend available in the current VM
      "bench.backends": ["run bench/backends_bench.exs"],
      # Start distribution so the C-Node backend can be included
      "bench.backends.all": ["cmd ./bin/bench_backends_all.sh"],
      "bench.all": ["bench", "bench.backends"],
      # C-Node specific tests (requires distribution)
      # C-Node integration tests
      "test.cnode": ["cmd ./bin/test_cnode.sh"],

      # Release
      release: ["git_ops.release"]
    ]
  end

  defp test_nif(args) do
    previous = System.get_env("EX_MAUDE_BUILD")
    System.put_env("EX_MAUDE_BUILD", "1")

    try do
      Mix.Task.run("compile", ["--force"])
      Mix.Task.reenable("test")

      Mix.Task.run(
        "test",
        [
          "--include",
          "nif",
          "--include",
          "integration",
          "--exclude",
          "network",
          "--exclude",
          "cnode",
          "test/ex_maude/backend/nif_test.exs",
          "test/ex_maude/backend/nif_integration_test.exs",
          "test/ex_maude/backend/nif_lifecycle_test.exs"
          | args
        ]
      )
    after
      if previous,
        do: System.put_env("EX_MAUDE_BUILD", previous),
        else: System.delete_env("EX_MAUDE_BUILD")
    end
  end
end
