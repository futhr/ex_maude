defmodule ExMaude.Bench.SearchBudget do
  @moduledoc "Thirty declared helper-only samples after actual deadline preflight."
  alias ExMaude.Verification.Budget
  alias ExMaude.Verification.SearchRun
  @model "mod BUDGET-SMOKE is protecting NAT . endm\n"
  @query %{module: "BUDGET-SMOKE", initial: "0", pattern: "0", max_depth: 1, max_solutions: 1}
  @input %{timeout: 50, deadline: -100, now: -110}

  @spec run() :: :ok
  def run do
    executable = System.get_env("BENCH_BINARY") || ExMaude.Binary.find()
    executable || raise "Maude executable required"
    source = source()

    {:ok, completed} =
      SearchRun.run(@model, @query,
        maude_path: executable,
        deadline_ms: System.monotonic_time(:millisecond) + 2000
      )

    completed.termination == :solution_limit || raise "finite preflight failed"

    {:error, %ExMaude.Error{type: :timeout}} =
      expired =
      SearchRun.run(@model, @query,
        maude_path: executable,
        deadline_ms: System.monotonic_time(:millisecond) - 1
      )

    {:ok, 10} = calculate()
    {:error, :expired} = Budget.remaining(50, -100, -100)
    {:error, :invalid} = Budget.remaining(0, -100, -110)
    {:ok, 50} = Budget.remaining(50, :none, -110)
    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)
    input_bytes = :erlang.term_to_binary(%{input: @input, completed: completed, expired: expired})
    File.write!(Path.join(directory, "input.etf"), input_bytes)

    intervals =
      for group <- 1..5, sample <- 1..6 do
        started = System.monotonic_time(:microsecond)
        actual = calculate()
        ended = System.monotonic_time(:microsecond)

        File.write!(
          Path.join(directory, "result-#{group}-#{sample}.etf"),
          :erlang.term_to_binary(actual)
        )

        {:ok, 10} = actual

        %{
          group: group,
          sample: sample,
          start_us: started,
          end_us: ended,
          duration_us: ended - started
        }
      end

    report = %{
      schema: "ex_maude.budget-smoke.v1",
      source: source,
      executable_digest: completed.executable_digest,
      executable_version: completed.executable_version,
      input_digest: digest(input_bytes),
      model_digest: completed.model_digest,
      query_digest: completed.query_digest,
      sample_count: 30,
      intervals: intervals,
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      os: inspect(:os.type())
    }

    File.write!(
      Path.join(directory, "search_budget.json"),
      Jason.encode!(report, pretty: true) <> "\n"
    )

    IO.puts("Search budget correctness passed; thirty helper-only samples retained")
  end

  defp calculate, do: Budget.remaining(@input.timeout, @input.deadline, @input.now)

  defp source do
    {_, 0} = System.cmd("git", ["diff", "--exit-code"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {index, 0} = System.cmd("git", ["write-tree"])
    %{commit: String.trim(commit), staged_tree: String.trim(index)}
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

ExMaude.Bench.SearchBudget.run()
