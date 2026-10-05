defmodule ExMaude.Bench.SearchVersion do
  @moduledoc "Thirty declared decoder-only samples over measured Maude version bytes."
  alias ExMaude.Verification.SearchRun
  alias ExMaude.Verification.Version
  @model "mod VERSION-SMOKE is protecting NAT . endm\n"
  @query %{module: "VERSION-SMOKE", initial: "0", pattern: "0", max_depth: 1, max_solutions: 1}

  @spec run() :: :ok
  def run do
    executable = System.get_env("BENCH_BINARY") || ExMaude.Binary.find()
    executable || raise "Maude executable required"
    {_, 0} = System.cmd("git", ["diff", "--exit-code"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {tree, 0} = System.cmd("git", ["write-tree"])
    {:ok, raw, 0} = ExMaude.Subprocess.run(executable, ["--version"], 5000, 65_536)
    {:ok, version} = Version.decode(raw)
    {:ok, receipt} = SearchRun.run(@model, @query, maude_path: executable)
    :solution_limit = receipt.termination
    ^version = receipt.executable_version

    refusals =
      for input <- ["", " \t\r\n", <<255>>, "v" <> <<0>>, nil, :binary.copy("v", 65_537)] do
        actual = Version.decode(input)
        {:error, %ExMaude.Error{}} = actual
        %{input: input, actual: actual}
      end

    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)
    bytes = :erlang.term_to_binary(%{raw: raw, preflight: receipt, refusals: refusals})
    File.write!(Path.join(directory, "input.etf"), bytes)

    intervals =
      for group <- 1..5, sample <- 1..6 do
        started = System.monotonic_time(:microsecond)
        actual = Version.decode(raw)
        ended = System.monotonic_time(:microsecond)

        File.write!(
          Path.join(directory, "result-#{group}-#{sample}.etf"),
          :erlang.term_to_binary(actual)
        )

        {:ok, ^version} = actual

        %{
          group: group,
          sample: sample,
          start_us: started,
          end_us: ended,
          duration_us: ended - started
        }
      end

    report = %{
      schema: "ex_maude.version-smoke.v1",
      source: %{commit: String.trim(commit), tree: String.trim(tree)},
      executable_digest: receipt.executable_digest,
      executable_version: version,
      input_digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      sample_count: 30,
      intervals: intervals,
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      os: inspect(:os.type())
    }

    File.write!(Path.join(directory, "search_version.json"), Jason.encode!(report, pretty: true))
    IO.puts("Version correctness passed; thirty decoder-only samples retained")
  end
end

ExMaude.Bench.SearchVersion.run()
