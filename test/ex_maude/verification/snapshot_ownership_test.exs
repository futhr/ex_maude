defmodule ExMaude.Verification.SnapshotOwnershipTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import Bitwise
  @moduletag :integration

  property "generated snapshot schedules retain independent exact bytes" do
    check all(
            number <- integer(0..100),
            disposition <- member_of([:close, :loss]),
            max_runs: 300
          ) do
      first_bytes = "first #{number}\n"
      second_bytes = "second #{number}\n"
      record = record(%{number: number, disposition: disposition}, "snapshot")
      {first, first_ref, first_path, _} = start_snapshot(:first, first_bytes)
      {second, second_ref, second_path, second_lease} = start_snapshot(:second, second_bytes)

      on_exit(fn ->
        for owner <- [first, second], do: Process.exit(owner, :kill)
        for path <- [first_path, second_path], do: File.rm_rf(Path.dirname(path))
      end)

      before = {File.read(first_path), File.read(second_path)}
      foreign = apply(ExMaude.Verification.Snapshot, :close, [second_lease])
      mode = File.stat!(second_path).mode &&& 0o777
      directory_mode = File.stat!(Path.dirname(second_path)).mode &&& 0o777
      if disposition == :close, do: send(first, :close), else: Process.exit(first, :kill)
      assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 1000
      removed = eventually(fn -> not File.exists?(Path.dirname(first_path)) end)
      unaffected = File.read(second_path)
      send(second, :close)
      assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, 1000
      final_removed = not File.exists?(Path.dirname(second_path))

      actual = %{
        before: before,
        foreign: foreign,
        mode: mode,
        directory_mode: directory_mode,
        removed: removed,
        unaffected: unaffected,
        final_removed: final_removed
      }

      retain(record, actual)
      assert before == {{:ok, first_bytes}, {:ok, second_bytes}}
      assert {:error, %ExMaude.Error{type: :validation}} = foreign
      assert mode == 0o400
      assert directory_mode == 0o700
      assert removed
      assert unaffected == {:ok, second_bytes}
      assert final_removed
    end
  end

  defp start_snapshot(key, bytes) do
    parent = self()

    {owner, ref} =
      spawn_monitor(fn ->
        result = apply(ExMaude.Verification.Snapshot, :start, [bytes])
        send(parent, {:snapshot, key, result})
        {:ok, lease, _} = result

        receive do
          :close -> apply(ExMaude.Verification.Snapshot, :close, [lease])
        end
      end)

    assert_receive {:snapshot, ^key, {:ok, lease, path}}, 1000
    {owner, ref, path, lease}
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

  defp record(input, kind) do
    if directory = System.get_env("PREPARATION_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      path = Path.join(directory, "#{kind}-#{System.unique_integer([:positive])}")
      File.write!(path <> ".etf", :erlang.term_to_binary(input))
      path
    end
  end

  defp retain(nil, _), do: :ok

  defp retain(path, actual),
    do: File.write!(path <> "-actual.etf", :erlang.term_to_binary(actual))
end
