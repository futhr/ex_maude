defmodule ExMaude.Bench do
  @moduledoc """
  Main benchmark suite for ExMaude.

  This module measures the performance of both the pure Elixir parsing layer
  and the Maude integration layer, helping identify bottlenecks and validate
  that the worker pool provides expected concurrency benefits.

  ## Why Benchmark?

  ExMaude is designed for applications that may perform many Maude operations,
  such as IoT rule conflict detection or formal verification workflows. Understanding
  performance characteristics helps:

    1. Identify bottlenecks in the parsing vs. Maude execution pipeline
    2. Validate that the worker pool provides expected concurrency benefits
    3. Ensure parsing overhead is minimal compared to Maude execution time
    4. Guide decisions about pool sizing for production deployments

  ## Running Benchmarks

      # Run full benchmark suite (requires Maude installed)
      mix run bench/run.exs

      # Or if you have a bench alias defined
      mix bench

  ## Benchmark Categories

  ### Parser Benchmarks (No Maude Required)

  These measure the pure Elixir parsing functions that convert Maude's text
  output into structured Elixir data. Fast parsing is important because:

    - Every Maude command result must be parsed
    - Search operations may return many solutions to parse
    - Parsing should not become a bottleneck in high-throughput scenarios

  ### Maude Reduce Benchmarks (Requires Maude)

  These measure the full round-trip time for term reduction:

    - `reduce simple` - Baseline: minimal computation (1 + 1)
    - `reduce medium` - Moderate computation with multiple operations
    - `reduce bool` - Different sort (Bool) to verify consistent performance

  This helps understand the fixed overhead of Maude communication vs.
  the variable cost of actual computation.

  ### Pool Benchmarks (Requires Maude)

  These measure the Poolboy worker pool operations:

    - `pool transaction` - Full checkout/execute/checkin cycle
    - `pool status` - Pool introspection overhead

  Understanding pool overhead helps tune pool_size and max_overflow settings.

  ### Concurrency Benchmarks (Requires Maude)

  These compare sequential vs. parallel execution to validate that the
  worker pool actually provides concurrency benefits:

    - `sequential 5 reduces` - Execute 5 reductions one after another
    - `parallel 5 reduces` - Execute 5 reductions concurrently via Task.async_stream

  With a pool_size of 4, parallel execution should be significantly faster
  for CPU-bound Maude operations.

  ## Interpreting Results

  Key metrics to watch:

    - **ips** (iterations per second) - Higher is better
    - **average** - Mean execution time per operation
    - **memory** - Memory allocated per operation

  Expected patterns:

    - Parser operations should be microseconds (µs)
    - Maude operations should be milliseconds (ms) due to IPC overhead
    - Parallel execution should show ~3-4x speedup with pool_size: 4
  """

  @doc """
  Runs the complete benchmark suite.

  Executes parser benchmarks unconditionally, then runs Maude integration
  benchmarks if Maude is available on the system.
  """
  def run do
    IO.puts("ExMaude Benchmark Suite")
    IO.puts("=======================")
    IO.puts("")

    parser_benchmarks()

    # Check for Maude in system PATH or local priv directory
    maude_path =
      System.find_executable("maude") ||
        find_local_maude()

    if maude_path do
      IO.puts("Maude found at: " <> maude_path)
      Application.put_env(:ex_maude, :maude_path, maude_path)
      # Disable PTY wrapper to avoid "openpty: Device not configured" errors
      Application.put_env(:ex_maude, :use_pty, false)
      # Start the pool via the supervisor
      {:ok, _} = Supervisor.start_child(ExMaude.Supervisor, ExMaude.Pool.child_spec([]))
      Process.sleep(1000)
      maude_benchmarks()
    else
      IO.puts("WARNING: Maude not found. Install with: mix maude.install")
    end
  end

  defp parser_benchmarks do
    IO.puts("")
    IO.puts("--- Parser Benchmarks ---")
    IO.puts("")

    search_output = """
    Solution 1 (state 5)
    S:State --> active

    Solution 2 (state 8)
    S:State --> inactive
    """

    reduce_output = "result Nat: 12345"

    module_list = """
    fmod BOOL
    fmod NAT
    mod MY-MOD
    """

    complex_term = "f(g(h(a, b)), j(k(e)))"

    Benchee.run(
      %{
        "parse_search_results" => fn -> ExMaude.Parser.parse_search_results(search_output) end,
        "parse_result" => fn -> ExMaude.Parser.parse_result(reduce_output) end,
        "parse_module_list" => fn -> ExMaude.Parser.parse_module_list(module_list) end,
        "parse_term" => fn -> ExMaude.Parser.parse_term(complex_term) end,
        "parse_errors" => fn -> ExMaude.Parser.parse_errors("result Nat: 42") end
      },
      warmup: 2,
      time: 5,
      memory_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown, file: "BENCHMARKS.md", description: """
        # ExMaude Performance Benchmarks

        Comprehensive performance benchmarks for ExMaude's parser and Maude integration.

        ## System Information

        Run on: #{DateTime.utc_now() |> DateTime.to_string()}

        ## About These Benchmarks

        ExMaude is designed for applications performing many Maude operations (IoT rule conflict
        detection, formal verification). These benchmarks help:

        - Identify bottlenecks in parsing vs. Maude execution
        - Validate worker pool concurrency benefits
        - Ensure parsing overhead is minimal
        - Guide pool sizing for production deployments

        For backend comparison (Port vs C-Node), see `bench/BACKEND_COMPARISON.md`.

        ## Parser Benchmarks (Pure Elixir, No Maude Required)
        """}
      ]
    )
  end

  defp maude_benchmarks do
    IO.puts("")
    IO.puts("--- Maude Reduce Benchmarks ---")
    IO.puts("")

    Benchee.run(
      %{
        "reduce simple" => fn -> ExMaude.reduce("NAT", "1 + 1") end,
        "reduce medium" => fn -> ExMaude.reduce("NAT", "10 * 9 * 8 * 7 * 6") end,
        "reduce bool" => fn -> ExMaude.reduce("BOOL", "true and false") end
      },
      warmup: 2,
      time: 10,
      memory_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown, file: "BENCHMARKS.md", description: """
        ## Maude Reduce Benchmarks

        Full round-trip time for term reduction including IPC overhead.
        """}
      ]
    )

    IO.puts("")
    IO.puts("--- Pool Benchmarks ---")
    IO.puts("")

    Benchee.run(
      %{
        "pool transaction" => fn ->
          ExMaude.Pool.transaction(fn worker ->
            ExMaude.Server.execute(worker, "reduce in NAT : 1 + 1 .")
          end)
        end,
        "pool status" => fn -> ExMaude.Pool.status() end
      },
      warmup: 2,
      time: 5,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown, file: "BENCHMARKS.md", description: """
        ## Pool Benchmarks

        Poolboy worker pool operation overhead.
        """}
      ]
    )

    IO.puts("")
    IO.puts("--- Concurrency Benchmarks ---")
    IO.puts("")

    Benchee.run(
      %{
        "sequential 5 reduces" => fn ->
          for _ <- 1..5, do: ExMaude.reduce("NAT", "1 + 1")
        end,
        "parallel 5 reduces" => fn ->
          1..5
          |> Task.async_stream(fn _ -> ExMaude.reduce("NAT", "1 + 1") end, max_concurrency: 4)
          |> Enum.to_list()
        end
      },
      warmup: 2,
      time: 10,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.Markdown, file: "BENCHMARKS.md", description: """
        ## Concurrency Benchmarks

        Validates worker pool provides expected concurrency benefits.
        With pool_size: 4, parallel execution should show significant speedup.
        """}
      ]
    )
  end

  defp find_local_maude do
    # Check for Maude installed via mix maude.install
    local_path =
      :ex_maude
      |> :code.priv_dir()
      |> Path.join("maude/bin/maude")

    if File.exists?(local_path) do
      local_path
    else
      nil
    end
  end
end

ExMaude.Bench.run()
