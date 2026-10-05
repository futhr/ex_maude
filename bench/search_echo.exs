defmodule ExMaude.Bench.SearchEcho do
  @moduledoc "Thirty declared matcher-only samples over an actual Maude echo."
  alias ExMaude.Backend.Port
  alias ExMaude.Verification.CommandEcho
  alias ExMaude.Verification.SearchRun

  @model """
  mod ECHO-SMOKE is
    protecting NAT .
    sort S .
    op pair : Nat Nat -> S [ctor] .
    op bad : -> S [ctor] .
    rl [fail] : pair(2, 3) => bad .
  endm
  """
  @query %{
    module: "ECHO-SMOKE",
    initial: "pair(2,3)",
    pattern: "bad",
    max_depth: 2,
    max_solutions: 2
  }

  @spec run() :: :ok
  def run do
    executable = System.get_env("BENCH_BINARY") || ExMaude.Binary.find()
    executable || raise "Maude executable required"
    source = source()
    {:ok, compact} = SearchRun.run(@model, @query, maude_path: executable)

    {:ok, spaced} =
      SearchRun.run(@model, %{@query | initial: "pair(2, 3)"}, maude_path: executable)

    compact.termination == :completed_declared_bound || raise "compact query failed"

    (compact.solutions == spaced.solutions and compact.trace.bytes == spaced.trace.bytes) ||
      raise "changed result"

    compact.query_digest != spaced.query_digest || raise "query identity lost"

    command =
      ExMaude.Command.search(@query.module, @query.initial, @query.pattern,
        max_depth: 2,
        max_solutions: 2
      )
      |> ExMaude.Command.normalize()

    raw = echo(executable, command)
    true = CommandEcho.matches?(raw, command)
    false = CommandEcho.matches?(raw, String.replace(command, "pair(2,3)", "pair(2,4)"))
    false = CommandEcho.matches?("search \"a b\" .\n", "search \"ab\" .")
    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "input.etf"),
      :erlang.term_to_binary(%{raw: raw, command: command, compact: compact, spaced: spaced})
    )

    intervals =
      for group <- 1..5, sample <- 1..6 do
        started = System.monotonic_time(:microsecond)
        actual = CommandEcho.matches?(raw, command)
        ended = System.monotonic_time(:microsecond)

        File.write!(
          Path.join(directory, "result-#{group}-#{sample}.etf"),
          :erlang.term_to_binary(actual)
        )

        true = actual

        %{
          group: group,
          sample: sample,
          start_us: started,
          end_us: ended,
          duration_us: ended - started
        }
      end

    report = %{
      schema: "ex_maude.echo-smoke.v1",
      source: source,
      executable_digest: compact.executable_digest,
      executable_version: compact.executable_version,
      input_digest: digest(raw),
      command_digest: digest(command),
      sample_count: 30,
      intervals: intervals,
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release))
    }

    File.write!(
      Path.join(directory, "search_echo.json"),
      Jason.encode!(report, pretty: true) <> "\n"
    )

    IO.puts("Search echo correctness passed; thirty matcher-only samples retained")
  end

  defp echo(executable, command) do
    path =
      Path.join(
        System.tmp_dir!(),
        "echo-smoke-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}.maude"
      )

    File.write!(path, @model)

    try do
      {:ok, worker} =
        Port.start_link(
          maude_path: executable,
          preload_modules: [path],
          isolated_preloads: true,
          use_pty: false,
          startup_timeout_ms: 30_000,
          max_response_bytes: 16_777_216
        )

      try do
        {:ok, raw} = Port.execute(worker, command, timeout: 30_000)
        raw
      after
        Port.stop(worker)
      end
    after
      File.rm!(path)
    end
  end

  defp source do
    {_, 0} = System.cmd("git", ["diff", "--exit-code"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {index, 0} = System.cmd("git", ["write-tree"])
    %{commit: String.trim(commit), staged_tree: String.trim(index)}
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

ExMaude.Bench.SearchEcho.run()
