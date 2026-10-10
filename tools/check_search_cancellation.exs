defmodule ExMaude.CancellationCampaign do
  @moduledoc false

  @test "test/ex_maude/verification/cancellation_test.exs"
  @seeds [20_261_005, 27_182_818, 31_415_926]
  @mutants [
    {"cancel-as-worker-loss", "lib/ex_maude/verification/search_run.ex",
     "defp settle({:ok, receipt}, {:ok, :cancelled}), do: incomplete(receipt, :cancelled)",
     "defp settle({:ok, receipt}, {:ok, :cancelled}), do: incomplete(receipt, :worker_loss)"},
    {"accept-late-request", "lib/ex_maude/verification/cancellation.ex",
     "def handle_call(:request, _, %{closed: false} = state)",
     "def handle_call(:request, _, %{closed: _} = state)"}
  ]

  def run do
    Enum.each(Application.spec(:ex_maude, :modules), &Code.ensure_loaded!/1)
    root = File.cwd!()
    output = Path.join(Mix.Project.build_path(), "cancellation-campaign-#{nonce()}")
    File.mkdir_p!(output)

    {paths, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])

    paths = String.split(paths, <<0>>, trim: true) |> Enum.uniq() |> Enum.sort()
    inputs = Map.new(paths, fn path -> {path, digest(File.read!(path))} end)
    write(output, "inputs.json", inputs)
    archive = Path.join(output, "source.tar")
    :ok = :erl_tar.create(String.to_charlist(archive), Enum.map(paths, &String.to_charlist/1), [])
    maude = ExMaude.Binary.find() || raise "Maude executable is required"

    baseline_paths = %{
      deps: Path.join(output, "otp28-baseline-deps"),
      build: Path.join(output, "otp28-baseline-build")
    }

    File.cp_r!(Mix.Project.deps_path(), baseline_paths.deps)

    baseline =
      for seed <- @seeds do
        directory = Path.join(output, "seed-#{seed}")
        command = ["test", "--include", "integration", @test, "--seed", Integer.to_string(seed)]
        {log, status} = mix(root, command, directory, maude, baseline_paths)
        File.write!(directory <> ".log", log)
        status == 0 || raise "baseline failed: #{seed}"
        String.contains?(log, "1 property, 9 tests, 0 failures") || raise "incomplete baseline"
        validate_records(directory, 300)
        %{seed: seed, schedules: 300}
      end

    mutants = Enum.map(@mutants, &mutant(&1, archive, baseline_paths, output, maude))

    {current_paths, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])

    String.split(current_paths, <<0>>, trim: true) |> Enum.uniq() |> Enum.sort() == paths ||
      raise "source inventory changed during campaign"

    inputs == Map.new(paths, fn path -> {path, digest(File.read!(path))} end) ||
      raise "source changed during campaign"

    write(output, "report.json", %{
      schema: "ex_maude.cancellation-campaign.v1",
      baseline: baseline,
      source_archive_digest: digest(File.read!(archive)),
      mutants: mutants,
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      executable_digest: digest(File.read!(maude))
    })

    IO.puts(
      "Cancellation campaign passed: 900 real Maude schedules and two compiled mutants; #{output}"
    )
  end

  defp mutant({id, file, before, replacement}, archive, baseline_paths, output, maude) do
    directory =
      Path.join(System.tmp_dir!(), "ex_maude_mutant_#{id}_#{nonce()}")

    File.mkdir!(directory)

    try do
      :ok = :erl_tar.extract(String.to_charlist(archive), [{:cwd, String.to_charlist(directory)}])
      paths = %{deps: Path.join(directory, "deps"), build: Path.join(directory, "_build/test")}
      File.cp_r!(baseline_paths.deps, paths.deps)
      File.mkdir_p!(Path.dirname(paths.build))
      File.cp_r!(baseline_paths.build, paths.build)
      # Rebuild the producer so its priv links belong to this mutant checkout.
      File.rm_rf!(Path.join(paths.build, "lib/ex_maude"))
      path = Path.join(directory, file)
      source = File.read!(path)

      length(:binary.matches(source, before)) == 1 ||
        raise "mutant does not have one exact target"

      File.write!(path, String.replace(source, before, replacement, global: false))
      evidence = Path.join(output, id)

      {compile, compile_status} =
        mix(
          directory,
          ["compile", "--force", "--warnings-as-errors"],
          evidence,
          maude,
          paths,
          "test"
        )

      File.write!(evidence <> "-compile.log", compile)
      compile_status == 0 || raise "mutation compilation failed: #{id}"
      line = property_line(Path.join(directory, @test))

      {log, status} =
        mix(
          directory,
          ["test", "--include", "integration", "#{@test}:#{line}", "--seed", "20261005"],
          evidence,
          maude,
          paths
        )

      File.write!(evidence <> ".log", log)
      File.cp!(path, evidence <> "-source.ex")
      status == 2 || raise "mutant did not fail ExUnit assertions: #{id}, #{status}"

      String.contains?(log, "1 property, 1 failure (9 excluded)") ||
        raise "missing property failure"

      String.contains?(log, "StreamData.shrink_failure") || raise "missing reducer execution"
      originals = Path.wildcard(Path.join(evidence, "schedule-*.json"))

      Enum.any?(originals, fn original ->
        input = original |> File.read!() |> Jason.decode!()

        input["requests"] == 1 and input["query"]["initial"] == "0" and
          File.exists?(Path.rootname(original) <> ".etf")
      end) || raise "missing minimal recorded schedule"

      %{id: id, status: status, compiled: true, property_failure: true, reduction: true}
    after
      File.rm_rf!(directory)
    end
  end

  defp property_line(path) do
    File.read!(path)
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, "property \"generated"))
    |> Kernel.+(1)
  end

  defp mix(directory, args, evidence, maude, paths, environment \\ "test") do
    File.mkdir_p!(evidence)

    # Set native-build policy after mise has applied the checkout's environment.
    System.cmd(
      "mise",
      [
        "exec",
        "elixir@1.19.4-otp-28",
        "erlang@28.5",
        "--",
        "env",
        "EX_MAUDE_BUILD=0",
        "EX_MAUDE_BUILD_CNODE=0",
        "mix" | args
      ],
      cd: directory,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", environment},
        {"MIX_BUILD_PATH", paths.build},
        {"MIX_BUILD_ROOT", nil},
        {"MIX_DEPS_PATH", paths.deps},
        {"MIX_LOCKFILE", nil},
        {"MAUDE_PATH", maude},
        {"CANCEL_EVIDENCE_DIR", evidence},
        {"MISE_ACTIVATE_AGGRESSIVE", "1"}
      ]
    )
  end

  defp validate_records(directory, expected) do
    originals = Path.wildcard(Path.join(directory, "schedule-*.json"))
    length(originals) == expected || raise "missing generated originals"

    for original <- originals do
      input = original |> File.read!() |> Jason.decode!()

      receipt =
        original
        |> Path.rootname()
        |> Kernel.<>(".etf")
        |> File.read!()
        |> :erlang.binary_to_term([:safe])

      Atom.to_string(receipt.termination) == input["expected"] || raise "wrong schedule outcome"
      receipt.model_digest == digest(input["model"]) || raise "wrong source identity"
      validate_receipt(receipt)
    end
  end

  defp validate_receipt(%{
         termination: :cancelled,
         solutions: [],
         states_explored: nil,
         trace: nil,
         depth_probe: nil,
         raw_output_digest: nil,
         error: %ExMaude.Error{type: :cancelled}
       }),
       do: :ok

  defp validate_receipt(%{termination: :solution_limit, solutions: [%{state_num: 0}]}), do: :ok
  defp validate_receipt(_), do: raise("incomplete generated receipt")

  defp write(directory, name, value),
    do: File.write!(Path.join(directory, name), Jason.encode!(value, pretty: true) <> "\n")

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end

ExMaude.CancellationCampaign.run()
