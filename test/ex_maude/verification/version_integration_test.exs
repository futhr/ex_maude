defmodule ExMaude.Verification.VersionIntegrationTest do
  use ExUnit.Case, async: false
  alias ExMaude.Verification.SearchRun
  @moduletag :integration
  @model "mod VERSION-IDENTITY is protecting NAT . endm\n"
  @query %{module: "VERSION-IDENTITY", initial: "0", pattern: "0", max_depth: 1, max_solutions: 1}

  @tag :tmp_dir
  test "missing or malformed version refuses before worker startup", %{tmp_dir: directory} do
    maude = ExMaude.Binary.find() || flunk("Maude executable required")
    version_file = Path.join(directory, "version")
    marker = Path.join(directory, "worker")
    path = Path.join(directory, "cli.sh")

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then cat '#{version_file}'; exit 0; fi
    printf 'worker' > '#{marker}'
    exec '#{maude}' "$@"
    """)

    File.chmod!(path, 0o700)

    for {bytes, name} <- [
          {"", "empty"},
          {" \r\n\t", "layout"},
          {<<255>>, "utf8"},
          {"version" <> <<0>>, "nul"}
        ] do
      File.write!(version_file, bytes)
      result = SearchRun.run(@model, @query, maude_path: path)
      retain(name, %{input: bytes, actual: result, worker_started: File.exists?(marker)})
      assert {:error, %ExMaude.Error{type: :load_error}} = result
      refute File.exists?(marker)
    end
  end

  test "actual finite Maude completion retains its measured version" do
    maude = ExMaude.Binary.find() || flunk("Maude executable required")
    assert {:ok, raw, 0} = ExMaude.Subprocess.run(maude, ["--version"], 5000, 65_536)
    assert {:ok, version} = ExMaude.Verification.Version.decode(raw)
    assert {:ok, receipt} = SearchRun.run(@model, @query, maude_path: maude)
    retain("actual-finite", %{raw_version: raw, actual: receipt})
    assert receipt.termination == :solution_limit
    assert receipt.executable_version == version
    assert version != ""
  end

  defp retain(name, value) do
    if directory = System.get_env("VERSION_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, name <> ".etf"), :erlang.term_to_binary(value))
    end
  end
end
