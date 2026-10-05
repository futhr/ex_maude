defmodule ExMaude.Bench.SearchSnapshot do
  @moduledoc "Five declared independent snapshot closure schedules."
  alias ExMaude.Verification.Snapshot
  @first "first snapshot\n"
  @second "second snapshot\n"

  @spec run() :: :ok
  def run do
    {_, 0} = System.cmd("git", ["diff", "--exit-code"])
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {tree, 0} = System.cmd("git", ["write-tree"])
    actual = schedule()
    validate(actual)
    directory = System.get_env("BENCH_OUTPUT_DIR", "bench/output")
    File.mkdir_p!(directory)
    bytes = :erlang.term_to_binary(%{first: @first, second: @second, preflight: actual})
    File.write!(Path.join(directory, "input.etf"), bytes)

    samples =
      for sample <- 1..5 do
        started = System.monotonic_time(:microsecond)
        actual = schedule()
        ended = System.monotonic_time(:microsecond)
        File.write!(Path.join(directory, "result-#{sample}.etf"), :erlang.term_to_binary(actual))
        validate(actual)
        %{sample: sample, start_us: started, end_us: ended, duration_us: ended - started}
      end

    report = %{
      schema: "ex_maude.snapshot-smoke.v1",
      commit: String.trim(commit),
      source_tree: String.trim(tree),
      input_digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      sample_count: 5,
      samples: samples,
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      os: inspect(:os.type())
    }

    File.write!(
      Path.join(directory, "search_snapshot.json"),
      Jason.encode!(report, pretty: true) <> "\n"
    )

    IO.puts("Snapshot correctness passed; five independent closure schedules retained")
  end

  defp schedule do
    {:ok, first, first_path} = Snapshot.start(@first)
    {:ok, second, second_path} = Snapshot.start(@second)

    try do
      before = {File.read(first_path), File.read(second_path)}
      first_close = Snapshot.close(first)
      first_after = File.read(first_path)
      second_before = File.read(second_path)
      second_close = Snapshot.close(second)
      second_after = File.read(second_path)
      {before, first_close, first_after, second_before, second_close, second_after}
    after
      for lease <- [first, second], Process.alive?(lease), do: Snapshot.close(lease)
    end
  end

  defp validate(actual) do
    {{{:ok, @first}, {:ok, @second}}, :ok, {:error, :enoent}, {:ok, @second}, :ok,
     {:error, :enoent}} = actual

    :ok
  end
end

ExMaude.Bench.SearchSnapshot.run()
