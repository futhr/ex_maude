defmodule ExMaude.PreparationCampaign do
  @moduledoc false

  @snapshot_test "test/ex_maude/verification/snapshot_ownership_test.exs"
  @native_test "test/ex_maude/subprocess_ownership_test.exs"
  @seeds [20_261_005, 27_182_818, 31_415_926]
  @mutants [
    {"omit-snapshot-cleanup", "lib/ex_maude/verification/snapshot.ex", "File.rm_rf(directory)",
     "File.rm_rf(Path.join(directory, \"omitted\"))", @snapshot_test},
    {"ignore-native-owner", "lib/ex_maude/subprocess.ex",
     "      {:DOWN, ^owner_ref, :process, _, _} ->\n        {:error, :owner_lost}",
     "      {:DOWN, ^owner_ref, :process, _, _} ->\n        collect(port, ownership, limit, chunks, size)",
     @native_test}
  ]

  @spec run() :: :ok
  def run do
    Enum.each(Application.spec(:ex_maude, :modules), &Code.ensure_loaded!/1)

    Enum.each(
      [
        :number,
        :disposition,
        :close,
        :loss,
        :before,
        :foreign,
        :mode,
        :directory_mode,
        :removed,
        :unaffected,
        :final_removed,
        :reason,
        :cap,
        :shutdown,
        :kill,
        :native_pid,
        :retired
      ],
      &Atom.to_string/1
    )

    root = File.cwd!()
    output = Path.join(root, "_build/preparation-campaign-#{nonce()}")
    File.mkdir_p!(output)

    {paths, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])

    paths =
      paths
      |> String.split(<<0>>, trim: true)
      |> Enum.uniq()
      |> Enum.sort()

    inputs = Map.new(paths, fn path -> {path, digest(File.read!(path))} end)
    write(output, "inputs.json", inputs)
    archive = Path.join(output, "source.tar")
    :ok = :erl_tar.create(String.to_charlist(archive), Enum.map(paths, &String.to_charlist/1), [])
    maude = ExMaude.Binary.find() || raise "Maude executable is required"

    baseline =
      for seed <- @seeds do
        directory = Path.join(output, "seed-#{seed}")

        command = [
          "test",
          "--include",
          "integration",
          @snapshot_test,
          @native_test,
          "test/ex_maude/verification/preparation_test.exs",
          "test/ex_maude/subprocess_test.exs",
          "test/ex_maude/subprocess_deadline_test.exs",
          "--seed",
          Integer.to_string(seed)
        ]

        {log, status} = mix(root, command, directory, maude)
        File.write!(directory <> ".log", log)
        status == 0 || raise "baseline failed: #{seed}"
        String.contains?(log, "2 properties, 7 tests, 0 failures") || raise "incomplete baseline"
        validate_records(directory, 300)
        %{seed: seed, snapshot_schedules: 300, subprocess_schedules: 300}
      end

    mutants = Enum.map(@mutants, &mutant(&1, archive, root, output, maude))

    {current_paths, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])

    current_paths =
      current_paths
      |> String.split(<<0>>, trim: true)
      |> Enum.uniq()
      |> Enum.sort()

    current_paths == paths ||
      raise "source inventory changed during campaign"

    inputs == Map.new(paths, fn path -> {path, digest(File.read!(path))} end) ||
      raise "source changed during campaign"

    write(output, "report.json", %{
      schema: "ex_maude.preparation-campaign.v1",
      baseline: baseline,
      source_archive_digest: digest(File.read!(archive)),
      mutants: mutants,
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      executable_digest: digest(File.read!(maude))
    })

    IO.puts(
      "Preparation campaign passed: 1800 ownership schedules, 21 directed cases and two compiled mutants; #{output}"
    )
  end

  defp mutant({id, file, before, replacement, test}, archive, root, output, maude) do
    directory =
      Path.join(System.tmp_dir!(), "ex_maude_mutant_#{id}_#{nonce()}")

    File.mkdir_p!(directory)
    :ok = :erl_tar.extract(String.to_charlist(archive), [{:cwd, String.to_charlist(directory)}])
    File.cp_r!(Path.join(root, "deps"), Path.join(directory, "deps"))
    File.mkdir_p!(Path.join(directory, "_build"))
    File.cp_r!(Path.join(root, "_build/test"), Path.join(directory, "_build/test"))
    path = Path.join(directory, file)
    source = File.read!(path)
    length(:binary.matches(source, before)) == 1 || raise "mutant does not have one exact target"
    File.write!(path, String.replace(source, before, replacement, global: false))
    evidence = Path.join(output, id)

    {compile, compile_status} =
      mix(directory, ["compile", "--force", "--warnings-as-errors"], evidence, maude, "test")

    File.write!(evidence <> "-compile.log", compile)
    compile_status == 0 || raise "mutation compilation failed: #{id}"
    line = property_line(Path.join(directory, test))

    {log, status} =
      mix(
        directory,
        ["test", "--include", "integration", "#{test}:#{line}", "--seed", "20261005"],
        evidence,
        maude
      )

    File.write!(evidence <> ".log", log)
    File.cp!(path, evidence <> "-source.ex")
    status == 2 || raise "mutant did not fail ExUnit assertions: #{id}, #{status}"

    String.contains?(log, "1 property, 1 failure") ||
      raise "missing property failure"

    String.contains?(log, "StreamData.shrink_failure") || raise "missing reducer execution"

    originals =
      originals(evidence, if(test == @snapshot_test, do: "snapshot", else: "subprocess"))

    Enum.any?(originals, fn original ->
      input = read(original)
      actual = read(Path.rootname(original) <> "-actual.etf")

      if test == @snapshot_test,
        do: input.number == 0 and (not actual.removed or not actual.final_removed),
        else: input.cap == 1 and not actual.retired
    end) || raise "missing minimal recorded ownership schedule"

    File.rm_rf!(directory)
    %{id: id, status: status, compiled: true, property_failure: true, reduction: true}
  end

  defp property_line(path) do
    File.read!(path)
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, "property \"generated"))
    |> Kernel.+(1)
  end

  defp mix(directory, args, evidence, maude, environment \\ "test") do
    File.mkdir_p!(evidence)

    System.cmd("mise", ["exec", "elixir@1.19.4-otp-28", "erlang@28.5", "--", "mix" | args],
      cd: directory,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", environment},
        {"EX_MAUDE_BUILD", "0"},
        {"EX_MAUDE_BUILD_CNODE", "0"},
        {"MAUDE_PATH", maude},
        {"PREPARATION_EVIDENCE_DIR", evidence},
        {"MISE_ACTIVATE_AGGRESSIVE", "1"}
      ]
    )
  end

  defp validate_records(directory, expected) do
    for kind <- ["snapshot", "subprocess"] do
      originals = originals(directory, kind)
      length(originals) == expected || raise "missing generated originals"

      for original <- originals do
        input = read(original)
        actual = read(Path.rootname(original) <> "-actual.etf")
        validate_observation(kind, input, actual)
      end
    end
  end

  defp originals(directory, kind) do
    Path.wildcard(Path.join(directory, "#{kind}-*.etf"))
    |> Enum.reject(&String.ends_with?(&1, "-actual.etf"))
  end

  defp validate_observation("snapshot", input, actual) do
    (input.number in 0..100 and input.disposition in [:close, :loss]) ||
      raise "invalid snapshot input"

    expected = {{:ok, "first #{input.number}\n"}, {:ok, "second #{input.number}\n"}}

    (actual.before == expected and actual.unaffected == elem(expected, 1)) ||
      raise "snapshot bytes changed"

    (actual.removed and actual.final_removed) || raise "snapshot was not retired"

    match?({:error, %ExMaude.Error{type: :validation}}, actual.foreign) ||
      raise "foreign closure accepted"

    (actual.mode == 0o400 and actual.directory_mode == 0o700) ||
      raise "private permissions changed"
  end

  defp validate_observation("subprocess", input, actual) do
    (input.cap in 1..64 and input.reason in [:kill, :shutdown]) ||
      raise "invalid subprocess input"

    (actual.retired and Regex.match?(~r/^[0-9]+$/, actual.native_pid)) ||
      raise "native child was not retired"
  end

  defp write(directory, name, value),
    do: File.write!(Path.join(directory, name), Jason.encode!(value, pretty: true) <> "\n")

  defp read(path) do
    File.read!(path) |> :erlang.binary_to_term([:safe])
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end

ExMaude.PreparationCampaign.run()
