defmodule ExMaude.Bench.Backends do
  @moduledoc """
  Comparative benchmarks for Port vs C-Node backends.

  This benchmark measures the performance difference between ExMaude's
  communication backends to help users choose the right backend for their
  workload.

  ## Backends

    * **Port** - Default backend using PTY wrapper. Full isolation, higher latency.
    * **C-Node** - Erlang distribution protocol. Full isolation, lower latency.
    * **NIF** - (Future) Native integration. Lowest latency, no isolation.

  ## Running

      # Run backend benchmarks
      mix run bench/backends_bench.exs

      # Or with alias
      mix bench.backends

  ## Metrics

    * Latency (p50, p99) - Response time distribution
    * Throughput - Operations per second
    * Memory - Heap usage per operation

  ## Expected Results

  | Scenario       | Port    | C-Node  | Notes                    |
  |----------------|---------|---------|--------------------------|
  | Simple reduce  | ~500μs  | ~100μs  | Fixed IPC overhead       |
  | Batch 100      | ~50ms   | ~10ms   | Amortized overhead       |
  | Concurrent 10  | ~100ms  | ~20ms   | Pool parallelism         |
  | Large term     | ~5ms    | ~1ms    | Serialization cost       |

  Note: Actual results vary by system. C-Node requires compiled binary.
  """

  alias ExMaude.Backend

  @warmup 2
  @time 10
  @parallel 1

  def run do
    IO.puts("ExMaude Backend Benchmarks")
    IO.puts("==========================")
    IO.puts("")

    backends = available_backends()

    if Enum.empty?(backends) do
      IO.puts("ERROR: No backends available. Ensure Maude is installed.")
      IO.puts("  mix maude.install")
      System.halt(1)
    end

    IO.puts("Backends to benchmark: #{inspect(backends)}")
    IO.puts("")

    run_simple_benchmarks(backends)
    run_batch_benchmarks(backends)
    run_large_term_benchmarks(backends)

    print_summary()
  end

  defp available_backends do
    backends = []

    # Always check Port first
    backends =
      if Backend.available?(:port) do
        IO.puts("✓ Port backend: AVAILABLE")
        backends ++ [:port]
      else
        IO.puts("✗ Port backend: UNAVAILABLE")
        backends
      end

    # Check C-Node with detailed status
    backends = backends ++ check_cnode()

    IO.puts("")
    backends
  end

  defp check_cnode do
    cond do
      # Binary not compiled
      not Backend.available?(:cnode) ->
        IO.puts("⚠️  C-Node backend: UNAVAILABLE (binary not compiled)")
        []

      # Binary exists but no distribution
      not Node.alive?() ->
        IO.puts("⚠️  C-Node backend: UNAVAILABLE (distribution not enabled)")
        []

      # All good!
      true ->
        IO.puts("✓ C-Node backend: AVAILABLE")
        [:cnode]
    end
  end

  defp print_summary do
    cond do
      # C-Node not compiled
      not Backend.available?(:cnode) ->
        IO.puts("")
        IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        IO.puts("✅ Benchmark completed (Port backend only)")
        IO.puts("")
        IO.puts("To enable C-Node benchmarks:")
        IO.puts("  1. Compile: cd c_src && make")
        IO.puts("  2. Run: mix bench.backends.all")
        IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

      # C-Node compiled but no distribution
      not Node.alive?() ->
        IO.puts("")
        IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        IO.puts("✅ Benchmark completed (Port backend only)")
        IO.puts("")
        IO.puts("💡 C-Node backend available but requires distribution")
        IO.puts("")
        IO.puts("To include C-Node (recommended for comparison):")
        IO.puts("  mix bench.backends.all")
        IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

      # All backends used
      true ->
        IO.puts("")
        IO.puts("✅ Benchmark completed (All backends)")
    end
  end

  defp run_simple_benchmarks(backends) do
    IO.puts("--- Simple Reduce Benchmarks ---")
    IO.puts("Single reduce operation latency")
    IO.puts("")

    scenarios =
      for backend <- backends, into: %{} do
        {"#{backend}: reduce 1+1", fn ->
          with_backend(backend, fn server ->
            Backend.impl().execute(server, "reduce in NAT : 1 + 1 .")
          end)
        end}
      end

    run_benchee(scenarios, """
    # ExMaude Backend Comparison

    Comparative performance benchmarks for ExMaude's communication backends.

    ## System Information

    Run on: #{DateTime.utc_now() |> DateTime.to_string()}

    ## About These Benchmarks

    ExMaude supports multiple backends for communicating with the Maude process:

    - **Port** - Default backend using PTY wrapper. Full isolation, higher latency.
    - **C-Node** - Erlang distribution protocol. Full isolation, lower latency.
    - **NIF** - (Future) Native integration. Lowest latency, no isolation.

    These benchmarks help you choose the right backend for your workload.

    ## Running These Benchmarks

    ```bash
    # Port backend only (no distribution required)
    mix bench.backends

    # All backends (Port + C-Node, automatic distribution)
    mix bench.backends.all
    ```

    ## Expected Results

    | Scenario       | Port    | C-Node  | Notes                    |
    |----------------|---------|---------|--------------------------|
    | Simple reduce  | ~500μs  | ~100μs  | Fixed IPC overhead       |
    | Batch 100      | ~50ms   | ~10ms   | Amortized overhead       |
    | Concurrent 10  | ~100ms  | ~20ms   | Pool parallelism         |
    | Large term     | ~5ms    | ~1ms    | Serialization cost       |

    **Note:** Actual results vary by system. C-Node requires compiled binary (`cd c_src && make`).

    ## Simple Reduce Benchmarks

    Single reduce operation latency (1 + 1).
    """)
  end

  defp run_batch_benchmarks(backends) do
    IO.puts("")
    IO.puts("--- Batch Reduce Benchmarks ---")
    IO.puts("100 sequential reduce operations")
    IO.puts("")

    scenarios =
      for backend <- backends, into: %{} do
        {"#{backend}: 100 reduces", fn ->
          with_backend(backend, fn server ->
            for i <- 1..100 do
              Backend.impl().execute(server, "reduce in NAT : #{i} + #{i} .")
            end
          end)
        end}
      end

    run_benchee(scenarios)
  end

  defp run_large_term_benchmarks(backends) do
    IO.puts("")
    IO.puts("--- Large Term Benchmarks ---")
    IO.puts("Reduce with deeply nested term (100 levels)")
    IO.puts("")

    large_term = build_large_term(100)

    scenarios =
      for backend <- backends, into: %{} do
        {"#{backend}: large term", fn ->
          with_backend(backend, fn server ->
            Backend.impl().execute(server, "reduce in NAT : #{large_term} .")
          end)
        end}
      end

    run_benchee(scenarios)
  end

  defp build_large_term(n) when n <= 1, do: "1"
  defp build_large_term(n), do: "(#{build_large_term(n - 1)} + 1)"

  defp with_backend(backend, fun) do
    # Temporarily set the backend
    original = Application.get_env(:ex_maude, :backend, :port)
    Application.put_env(:ex_maude, :backend, backend)

    # Get maude path
    maude_path = find_maude_path()
    Application.put_env(:ex_maude, :maude_path, maude_path)
    Application.put_env(:ex_maude, :use_pty, false)

    try do
      {:ok, server} = Backend.impl().start_link(maude_path: maude_path)

      try do
        fun.(server)
      after
        # Gracefully stop the server, catching any cleanup errors
        try do
          Backend.impl().stop(server)
          # Give C-Node a moment to flush pending I/O
          if backend == :cnode, do: Process.sleep(10)
        catch
          :exit, _ -> :ok
        end
      end
    after
      Application.put_env(:ex_maude, :backend, original)
    end
  end

  defp find_maude_path do
    System.find_executable("maude") ||
      find_local_maude() ||
      raise "Maude not found. Install with: mix maude.install"
  end

  defp find_local_maude do
    local_path =
      :ex_maude
      |> :code.priv_dir()
      |> Path.join("maude/bin/maude")

    if File.exists?(local_path), do: local_path, else: nil
  end

  defp run_benchee(scenarios, description \\ nil) do
    formatters = [
      Benchee.Formatters.Console,
      {Benchee.Formatters.Markdown,
       file: "bench/BACKEND_COMPARISON.md",
       description: description}
    ]

    Benchee.run(
      scenarios,
      warmup: @warmup,
      time: @time,
      parallel: @parallel,
      memory_time: 2,
      formatters: formatters
    )
  end
end

ExMaude.Bench.Backends.run()
