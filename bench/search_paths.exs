defmodule ExMaude.Bench.SearchPaths do
  @moduledoc """
  Thirty decoder-only smoke calls over a complete actual Maude path.

  Setup and complete result validation are outside each measured interval.
  The workload was declared before timing in structured-search-paths.md.
  """

  alias ExMaude.Verification.Path
  alias ExMaude.Verification.SearchRun

  @model """
  mod PATH-SMOKE is
    sort S .
    ops a b c : -> S [ctor] .
    rl [one] : a => b .
    rl [two] : b => c .
  endm
  """
  @query %{module: "PATH-SMOKE", initial: "a", pattern: "c", max_depth: 5, max_solutions: 5}

  def run do
    executable = System.get_env("BENCH_BINARY") || ExMaude.Binary.find()
    executable || raise "Maude executable is required"
    provenance = source()
    {:ok, receipt} = SearchRun.run(@model, @query, maude_path: executable)
    receipt.termination == :completed_declared_bound || raise "search did not complete"
    bytes = receipt.trace.bytes
    {:ok, preflight} = Path.decode(bytes, 2)
    validate(preflight, bytes)
    {:error, %ExMaude.Error{type: :parse_error}} = Path.decode(bytes, 3)
    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)
    File.write!(Elixir.Path.join(directory, "path-input.etf"), :erlang.term_to_binary(receipt))

    intervals =
      for group <- 1..5, sample <- 1..6 do
        started = System.monotonic_time(:microsecond)
        result = Path.decode(bytes, 2)
        ended = System.monotonic_time(:microsecond)
        name = "path-#{group}-#{sample}.etf"
        File.write!(Elixir.Path.join(directory, name), :erlang.term_to_binary(result))
        {:ok, decoded} = result
        validate(decoded, bytes)

        %{
          group: group,
          sample: sample,
          start_us: started,
          end_us: ended,
          duration_us: ended - started
        }
      end

    report = %{
      schema: "ex_maude.path-smoke.v1",
      source: provenance,
      executable_digest: receipt.executable_digest,
      executable_version: receipt.executable_version,
      model_digest: receipt.model_digest,
      query_digest: receipt.query_digest,
      input_digest: receipt.trace.digest,
      parser_version: preflight.parser_version,
      nodes: 3,
      edges: 2,
      sample_count: 30,
      intervals: intervals,
      environment: %{
        os: inspect(:os.type()),
        elixir: System.version(),
        otp: List.to_string(:erlang.system_info(:otp_release))
      }
    }

    File.write!(
      Elixir.Path.join(directory, "search_paths.json"),
      Jason.encode!(report, pretty: true) <> "\n"
    )

    IO.puts("Path decoder correctness passed; thirty decoder-only samples retained")
  end

  defp validate(decoded, bytes) do
    decoded.digest == digest(bytes) || raise "input digest differs"
    decoded.state_num == 2 || raise "wrong terminal state"

    decoded.nodes == [
      %{state_num: 0, sort: "S", value: "a"},
      %{state_num: 1, sort: "S", value: "b"},
      %{state_num: 2, sort: "S", value: "c"}
    ] || raise "lost node"

    decoded.edges == [
      %{from_state: 0, to_state: 1, rule: "rl [one] : a => b .", label: "one"},
      %{from_state: 1, to_state: 2, rule: "rl [two] : b => c .", label: "two"}
    ] || raise "lost edge"
  end

  defp source do
    {_, 0} = System.cmd("git", ["diff", "--exit-code"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {index, 0} = System.cmd("git", ["write-tree"])
    %{commit: String.trim(commit), staged_tree: String.trim(index)}
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

ExMaude.Bench.SearchPaths.run()
