defmodule ExMaude.Verification.PreparationTest do
  use ExUnit.Case, async: false
  alias ExMaude.Verification.SearchRun
  @moduletag :integration
  @model "mod PREPARATION is protecting NAT . endm\n"
  @query %{module: "PREPARATION", initial: "0", pattern: "0", max_depth: 1, max_solutions: 1}

  test "caller loss during version identification retires its native child" do
    {path, pid_file, _} = fixture(:version)
    {owner, ref} = start(path)
    assert eventually(fn -> pid_ready?(pid_file) end)
    native_pid = File.read!(pid_file)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    actual = eventually(fn -> retired?(native_pid) end)
    retain("version-loss", %{native_pid: native_pid, retired: actual})
    assert actual
    refute_receive {:search_result, _}
  end

  test "caller loss during model preload removes its snapshot and native child" do
    {path, pid_file, command_file} = fixture(:preload)
    {owner, ref} = start(path)
    assert eventually(fn -> File.exists?(command_file) end)
    command = File.read!(command_file)
    [_, model_path] = Regex.run(~r/^load "([^"]+)"\s*\.\s*$/, command)
    assert File.read!(model_path) == @model
    directory = Path.dirname(model_path)
    assert Path.dirname(directory) == Path.expand(System.tmp_dir!())
    on_exit(fn -> File.rm_rf(directory) end)
    native_pid = File.read!(pid_file)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    removed = eventually(fn -> not File.exists?(directory) end)
    retired = eventually(fn -> retired?(native_pid) end)
    retain("preload-loss", %{command: command, removed: removed, retired: retired})
    assert removed
    assert retired
    refute_receive {:search_result, _}
  end

  defp start(path) do
    parent = self()

    {owner, ref} =
      spawn_monitor(fn ->
        send(
          parent,
          {:search_result, SearchRun.run(@model, @query, maude_path: path, timeout: 5000)}
        )
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    {owner, ref}
  end

  defp fixture(phase) do
    stem = Path.join(System.tmp_dir!(), "preparation-#{nonce()}")
    path = stem <> ".sh"
    pid_file = stem <> ".pid"
    command_file = stem <> ".command"
    pending_command = command_file <> ".pending"

    version =
      if phase == :version,
        do: "printf '%s' \"$$\" > '#{pid_file}'; kill -STOP \"$$\"",
        else: "printf 'fixture 1\\n'; exit 0"

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then #{version}; fi
    printf '%s' "$$" > '#{pid_file}'
    printf 'Maude> '
    IFS= read -r line
    printf '%s' "$line" > '#{pending_command}'
    mv '#{pending_command}' '#{command_file}'
    kill -STOP "$$"
    """)

    File.chmod!(path, 0o700)

    on_exit(fn ->
      if File.exists?(pid_file), do: kill(File.read!(pid_file))
      Enum.each([path, pid_file, command_file, pending_command], &File.rm/1)
    end)

    {path, pid_file, command_file}
  end

  defp retired?(pid), do: elem(System.cmd("kill", ["-0", pid], stderr_to_stdout: true), 1) != 0

  defp pid_ready?(file) do
    case File.read(file) do
      {:ok, pid} -> Regex.match?(~r/^[1-9][0-9]*$/, pid)
      _ -> false
    end
  end

  defp kill(pid), do: System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp retain(name, value) do
    if directory = System.get_env("PREPARATION_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, name <> ".etf"), :erlang.term_to_binary(value))
    end
  end
end
