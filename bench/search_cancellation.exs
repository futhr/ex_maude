defmodule ExMaude.Bench.SearchCancellation do
  @moduledoc """
  Five correctness-gated public cancellation smoke samples, including startup.

  The declared workload is in docs/specs/search-run-cancellation.md. Reports
  retain raw intervals and complete receipts outside the measured operation.
  """

  alias ExMaude.Verification.Cancellation
  alias ExMaude.Verification.SearchRun

  @model """
  mod CANCEL-SMOKE is
    protecting NAT .
    rl [next] : N:Nat => s(N:Nat) .
  endm
  """
  @query %{module: "CANCEL-SMOKE", initial: "0", pattern: "0", max_depth: :unbounded}

  def run do
    path = System.get_env("BENCH_BINARY") || ExMaude.Binary.find()
    path || raise "Maude executable is required"
    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)
    provenance = source()
    preflight = execute(path)
    File.write!(Path.join(directory, "cancel-preflight.etf"), :erlang.term_to_binary(preflight))
    validate(preflight)

    samples =
      for number <- 1..5 do
        started = System.monotonic_time(:microsecond)
        receipt = execute(path)
        ended = System.monotonic_time(:microsecond)
        File.write!(Path.join(directory, "cancel-#{number}.etf"), :erlang.term_to_binary(receipt))
        validate(receipt)
        receipt.model_digest == preflight.model_digest || raise "model identity changed"
        receipt.query_digest == preflight.query_digest || raise "query identity changed"
        %{sample: number, start_us: started, end_us: ended, duration_us: ended - started}
      end

    report = %{
      schema: "ex_maude.search-cancellation-smoke.v1",
      workload:
        "instance startup, recorded early request, SearchRun startup/retirement, instance stop",
      source: provenance,
      executable_digest: preflight.executable_digest,
      executable_version: preflight.executable_version,
      model_digest: preflight.model_digest,
      query_digest: preflight.query_digest,
      outcome: "cancelled",
      sample_count: 5,
      intervals: samples,
      environment: %{
        os: inspect(:os.type()),
        elixir: System.version(),
        otp: List.to_string(:erlang.system_info(:otp_release))
      }
    }

    File.write!(
      Path.join(directory, "search_cancellation.json"),
      Jason.encode!(report, pretty: true) <> "\n"
    )

    IO.puts("Public cancellation correctness passed; five startup/retirement samples retained")
  end

  defp execute(path) do
    {:ok, instance} = Cancellation.start_link([])

    try do
      :ok = Cancellation.request(instance)
      {:ok, receipt} = SearchRun.run(@model, @query, maude_path: path, cancellation: instance)
      receipt
    after
      GenServer.stop(instance)
    end
  end

  defp validate(receipt) do
    %{
      termination: :cancelled,
      solutions: [],
      states_explored: nil,
      trace: nil,
      depth_probe: nil,
      raw_output_digest: nil,
      error: %ExMaude.Error{type: :cancelled}
    } = receipt

    receipt.model_digest == digest(@model) || raise "model bytes differ"
    receipt.limits.max_states == :unsupported || raise "invented state cap"
    :ok
  end

  defp source do
    {_, 0} = System.cmd("git", ["diff", "--exit-code"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {index, 0} = System.cmd("git", ["write-tree"])
    {patch, 0} = System.cmd("git", ["diff", "--cached", "--binary", "HEAD"])

    %{
      commit: String.trim(commit),
      staged_tree: String.trim(index),
      staged_patch_digest: digest(patch)
    }
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

ExMaude.Bench.SearchCancellation.run()
