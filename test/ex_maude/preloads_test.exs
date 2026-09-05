defmodule ExMaude.PreloadsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.Preloads

  setup do
    configured = Application.get_env(:ex_maude, :preload_modules)

    Application.put_env(:ex_maude, :preload_modules, ["/configured.maude"])

    for pool <- [:pool_a, :pool_b] do
      start_supervised!(
        ExMaude.Pool.child_spec(
          name: pool,
          pool_size: 1,
          pool_max_overflow: 0,
          maude_path: Path.expand("../support/fake_maude.sh", __DIR__),
          preload_modules: []
        )
      )
    end

    on_exit(fn ->
      restore(:preload_modules, configured)
    end)
  end

  test "keeps remembered modules isolated by pool" do
    assert :ok = Preloads.remember(:pool_a, "/a.maude")
    assert :ok = Preloads.remember(:pool_b, "/b.maude")

    assert Preloads.for_pool(:pool_a) == ["/configured.maude", "/a.maude"]
    assert Preloads.for_pool(:pool_b) == ["/configured.maude", "/b.maude"]
    assert Preloads.runtime_for_pool(:pool_a) == ["/a.maude"]
    assert Preloads.runtime_for_pool(:pool_b) == ["/b.maude"]
  end

  test "deduplicates configured and remembered modules" do
    assert :ok = Preloads.remember(:pool_a, "/configured.maude")
    assert Preloads.for_pool(:pool_a) == ["/configured.maude"]
  end

  test "does not lose concurrent updates" do
    paths = Enum.map(1..50, &"/concurrent-#{&1}.maude")

    paths
    |> Task.async_stream(&Preloads.remember(:pool_a, &1),
      max_concurrency: 50,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    remembered = Preloads.for_pool(:pool_a) -- ["/configured.maude"]
    assert MapSet.new(remembered) == MapSet.new(paths)
  end

  test "tracks loaded content without replaying its source path" do
    suffix = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "preload_identity_#{suffix}.maude")
    File.write!(path, "fmod PRELOAD-IDENTITY is endfm")
    on_exit(fn -> File.rm(path) end)

    assert :ok = Preloads.mark_loaded(:pool_a, [path], ExMaude.Pool.checkout(pool: :pool_a))
    assert {:ok, identity} = Preloads.identity(path)
    assert identity in Preloads.loaded_for_pool(:pool_a)
    refute path in Preloads.runtime_for_pool(:pool_a)
  end

  defp restore(key, nil), do: Application.delete_env(:ex_maude, key)
  defp restore(key, value), do: Application.put_env(:ex_maude, key, value)
end
