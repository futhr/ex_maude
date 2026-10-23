defmodule ExMaude.BuildRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @project_file Path.expand("../../mix.exs", __DIR__)
  @makefile Path.expand("../../c_src/Makefile", __DIR__)
  @check_file Path.expand("../../.check.exs", __DIR__)

  test "a clean checkout retains the C-Node gate before the bridge is built", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "c_src"))

    script =
      "{config, _} = Code.eval_file(System.fetch_env!(\"CHECK_CONFIG\")); " <>
        "tools = Keyword.fetch!(config, :tools); " <>
        "IO.inspect(tools |> Keyword.fetch!(:test_cnode) |> Keyword.fetch!(:enabled))"

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-e", script],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"CHECK_CONFIG", @check_file}]
      )

    assert status == 0, output
    assert String.trim(output) == "true"
  end

  test "a clean checkout can disable C or skip a missing compiler", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "c_src"))

    script =
      "Mix.start(); Code.compile_file(System.fetch_env!(\"PROJECT_FILE\")); " <>
        "IO.puts(:elixir_make in ExMaude.MixProject.project()[:compilers])"

    for {mode, compiler, expected} <- [
          {"0", "cc", "false"},
          {nil, "/nonexistent/ex_maude_cc", "false"},
          {"1", "/nonexistent/ex_maude_cc", "true"}
        ] do
      {output, status} =
        System.cmd(System.find_executable("elixir"), ["-e", script],
          cd: dir,
          stderr_to_stdout: true,
          env: [{"PROJECT_FILE", @project_file}, {"CC", compiler}, {"EX_MAUDE_BUILD_CNODE", mode}]
        )

      assert status == 0, output
      assert String.trim(output) == expected
    end
  end

  @tag skip: is_nil(System.find_executable("cc")) or is_nil(System.find_executable("make"))
  test "Makefile changes invalidate an otherwise current C build", %{tmp_dir: dir} do
    source_dir = Path.join(dir, "c_src")
    File.mkdir!(source_dir)
    File.cp!(@makefile, Path.join(source_dir, "Makefile"))
    File.write!(Path.join(source_dir, "maude_bridge.c"), "int main(void) { return 0; }\n")

    {output, status} =
      System.cmd("make", ["all"], cd: source_dir, stderr_to_stdout: true, env: [{"CC", "cc"}])

    assert status == 0, output
    assert File.regular?(Path.join(dir, "priv/maude_bridge"))

    assert {_, 0} =
             System.cmd("make", ["-q", "../priv/maude_bridge"],
               cd: source_dir,
               stderr_to_stdout: true
             )

    object_time = File.stat!(Path.join(source_dir, "maude_bridge.o"), time: :posix).mtime
    File.touch!(Path.join(source_dir, "Makefile"), object_time + 2)

    assert {_, 1} =
             System.cmd("make", ["-q", "../priv/maude_bridge"],
               cd: source_dir,
               stderr_to_stdout: true
             )
  end
end
