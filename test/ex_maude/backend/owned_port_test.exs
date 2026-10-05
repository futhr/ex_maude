defmodule ExMaude.Backend.OwnedPortTest do
  use ExUnit.Case, async: false
  alias ExMaude.Backend.Port, as: Backend
  @moduletag :integration

  test "owned ready workers remain unlinked and independently usable" do
    maude = ExMaude.Binary.find() || flunk("Maude executable required")
    {:ok, first} = Backend.start(maude_path: maude, use_pty: false, isolated_preloads: true)
    {:ok, second} = Backend.start(maude_path: maude, use_pty: false, isolated_preloads: true)

    on_exit(fn ->
      for worker <- [first, second], Process.alive?(worker), do: Backend.stop(worker)
    end)

    {:links, links} = Process.info(self(), :links)
    refute first in links
    refute second in links
    assert {:ok, "2"} = Backend.execute(first, "reduce in NAT : 1 + 1", timeout: 1000)
    assert :ok = Backend.stop(first)
    assert {:ok, "4"} = Backend.execute(second, "reduce in NAT : 2 + 2", timeout: 1000)
  end

  test "startup failure returns an error without altering exit flags" do
    {path, pid_file} = fixture("sleep 20")
    before = Process.info(self(), :trap_exit)

    assert {:error, {:maude_start_failed, :no_prompt}} =
             Backend.start(
               maude_path: path,
               use_pty: false,
               isolated_preloads: true,
               startup_timeout_ms: 50
             )

    assert Process.info(self(), :trap_exit) == before
    assert retired?(pid_file)
  end

  test "expired startup refuses before native process creation" do
    {path, pid_file} = fixture("printf 'Maude> '; sleep 20")

    assert {:error, {:maude_start_failed, :no_prompt}} =
             Backend.start(
               maude_path: path,
               use_pty: false,
               isolated_preloads: true,
               startup_deadline_ms: System.monotonic_time(:millisecond) - 1
             )

    refute File.exists?(pid_file)

    assert {:error, %ExMaude.Error{type: :validation}} =
             Backend.start(maude_path: path, startup_deadline_ms: nil)
  end

  test "owner death during startup retires the native process" do
    {path, pid_file} = fixture("sleep 20")
    parent = self()

    {owner, ref} =
      spawn_monitor(fn ->
        result =
          Backend.start(
            maude_path: path,
            use_pty: false,
            isolated_preloads: true,
            startup_timeout_ms: 5000
          )

        send(parent, {:startup_result, result})
      end)

    assert eventually(fn -> File.exists?(pid_file) end)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert retired?(pid_file)
    refute_receive {:startup_result, _}
  end

  test "owner death after readiness closes the owned worker" do
    {path, pid_file} = fixture("printf 'Maude> '; sleep 20")
    parent = self()

    {owner, ref} =
      spawn_monitor(fn ->
        {:ok, worker} = Backend.start(maude_path: path, use_pty: false, isolated_preloads: true)
        send(parent, {:owned_worker, worker})
        receive do: (:hold -> :ok)
      end)

    assert_receive {:owned_worker, worker}, 1000
    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
    assert retired?(pid_file)
  end

  defp fixture(action) do
    stem =
      Path.join(
        System.tmp_dir!(),
        "owned-port-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    path = stem <> ".sh"
    pid_file = stem <> ".pid"
    File.write!(path, "#!/bin/sh\nprintf '%s' \"$$\" > '#{pid_file}'\n#{action}\n")
    File.chmod!(path, 0o700)

    on_exit(fn ->
      File.rm(path)
      File.rm(pid_file)
    end)

    {path, pid_file}
  end

  defp retired?(pid_file) do
    os_pid = File.read!(pid_file) |> String.trim()
    eventually(fn -> elem(System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true), 1) != 0 end)
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
end
