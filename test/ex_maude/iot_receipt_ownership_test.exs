defmodule ExMaude.IoTReceiptOwnershipTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.IoT

  @moduletag :integration

  setup do
    previous = Application.fetch_env(:ex_maude, :maude_path)

    on_exit(fn ->
      case previous do
        {:ok, path} -> Application.put_env(:ex_maude, :maude_path, path)
        :error -> Application.delete_env(:ex_maude, :maude_path)
      end
    end)

    :ok
  end

  test "normal receipt completion removes its private snapshot and native child" do
    ready = fixture(:complete)

    assert {:ok, receipt} = run_receipt()
    {native_pid, checker_path} = observation(ready)
    directory = Path.dirname(checker_path)
    on_exit(fn -> File.rm_rf(directory) end)

    assert receipt.execution.completion == :bounded_complete
    assert receipt.execution.findings == []
    refute File.exists?(directory)
    assert eventually(fn -> retired?(native_pid) end)
  end

  test "caller loss during receipt preloading removes its snapshot and native child" do
    ready = fixture(:preload)
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn -> send(parent, {:receipt_result, run_receipt()}) end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert eventually(fn -> File.exists?(ready) end)
    {native_pid, checker_path} = observation(ready)
    directory = Path.dirname(checker_path)
    assert Path.basename(directory) =~ "ex_maude_receipt_"
    assert File.regular?(Path.join(directory, "iot-rules.maude"))

    # These are only the receipt caller's directly linked task and its linked
    # startup worker. Cleanup after a failed assertion is separate from proof.
    tasks = linked_processes(caller)
    workers = Enum.flat_map(tasks, &linked_processes/1) -- [caller]

    on_exit(fn ->
      for pid <- Enum.uniq(tasks ++ workers), do: Process.exit(pid, :kill)
      File.rm_rf(directory)
    end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    removed = eventually(fn -> not File.exists?(directory) end)
    retired = eventually(fn -> retired?(native_pid) end)

    assert removed, "caller loss left the private receipt snapshot"
    assert retired, "caller loss left the owned native receipt process"
    refute_receive {:receipt_result, _}
  end

  defp run_receipt do
    rules = [
      %{
        id: "owned-receipt",
        thing_id: "device",
        trigger: {:always},
        actions: [{:set_prop, "device", "state", "safe"}],
        priority: 1
      }
    ]

    IoT.verify_safety_with_receipt(rules, {:thing_state, "device", "state", "bad"},
      timeout: 10_000
    )
  end

  defp fixture(phase) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    directory = Path.join(System.tmp_dir!(), "ex_maude_receipt_fixture_" <> nonce)
    File.mkdir!(directory)
    path = Path.join(directory, "maude")
    ready = Path.join(directory, "ready")

    preload =
      if phase == :preload,
        do: "kill -STOP \"$$\"",
        else: "printf 'Maude> '"

    File.write!(path, """
    #!/bin/sh
    printf 'Maude> '
    while IFS= read -r line; do
      case "$line" in
        load*)
          printf '%s\\n%s\\n' "$$" "$0" > '#{ready}.pending'
          mv '#{ready}.pending' '#{ready}'
          #{preload}
          ;;
        search*) printf 'No solution.\\nMaude> ' ;;
        quit*) exit 0 ;;
        *) printf 'Maude> ' ;;
      esac
    done
    """)

    File.chmod!(path, 0o700)
    File.write!(Path.join(directory, "prelude.maude"), "fixture prelude\n")
    Application.put_env(:ex_maude, :maude_path, path)
    on_exit(fn -> File.rm_rf(directory) end)
    ready
  end

  defp observation(ready) do
    [pid, checker_path] =
      ready
      |> File.read!()
      |> String.split("\n", trim: true)

    assert pid =~ ~r/^[1-9][0-9]*$/
    {pid, checker_path}
  end

  defp linked_processes(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.filter(links, &is_pid/1)
      nil -> []
    end
  end

  defp retired?(pid), do: elem(System.cmd("kill", ["-0", pid], stderr_to_stdout: true), 1) != 0

  defp eventually(condition, attempts \\ 100)
  defp eventually(condition, 0), do: condition.()

  defp eventually(condition, attempts) do
    if condition.() do
      true
    else
      Process.sleep(10)
      eventually(condition, attempts - 1)
    end
  end
end
