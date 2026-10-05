defmodule ExMaude.SubprocessOwnershipTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  @moduletag :integration

  property "generated native children retire after caller loss" do
    check all(
            reason <- member_of([:kill, :shutdown]),
            cap <- integer(1..64),
            max_runs: 300
          ) do
      file = Path.join(System.tmp_dir!(), "subprocess-owner-#{nonce()}.pid")
      record = record(%{reason: reason, cap: cap})

      {owner, ref} =
        spawn_monitor(fn ->
          ExMaude.Subprocess.run(
            System.find_executable("sh"),
            ["-c", ~s(printf '%s' "$$" > "$1"; kill -STOP "$$"), "child", file],
            5000,
            cap
          )
        end)

      on_exit(fn ->
        Process.exit(owner, :kill)

        if File.exists?(file),
          do: System.cmd("kill", ["-KILL", File.read!(file)], stderr_to_stdout: true)

        File.rm(file)
      end)

      assert eventually(fn -> File.exists?(file) end)
      native_pid = File.read!(file)
      Process.exit(owner, reason)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1000

      retired =
        eventually(fn ->
          elem(System.cmd("kill", ["-0", native_pid], stderr_to_stdout: true), 1) != 0
        end)

      retain(record, %{native_pid: native_pid, retired: retired})
      assert retired
      File.rm!(file)
    end
  end

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

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp record(input) do
    if directory = System.get_env("PREPARATION_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      path = Path.join(directory, "subprocess-#{System.unique_integer([:positive])}")
      File.write!(path <> ".etf", :erlang.term_to_binary(input))
      path
    end
  end

  defp retain(nil, _), do: :ok

  defp retain(path, actual),
    do: File.write!(path <> "-actual.etf", :erlang.term_to_binary(actual))
end
