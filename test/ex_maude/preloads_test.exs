defmodule ExMaude.PreloadsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ExMaude.Preloads

  setup do
    configured = Application.get_env(:ex_maude, :preload_modules)
    runtime = Application.get_env(:ex_maude, :runtime_preload_modules_by_pool)

    Application.put_env(:ex_maude, :preload_modules, ["/configured.maude"])
    Application.delete_env(:ex_maude, :runtime_preload_modules_by_pool)

    on_exit(fn ->
      restore(:preload_modules, configured)
      restore(:runtime_preload_modules_by_pool, runtime)
    end)
  end

  test "keeps remembered modules isolated by pool" do
    assert :ok = Preloads.remember(:pool_a, "/a.maude")
    assert :ok = Preloads.remember(:pool_b, "/b.maude")

    assert Preloads.for_pool(:pool_a) == ["/configured.maude", "/a.maude"]
    assert Preloads.for_pool(:pool_b) == ["/configured.maude", "/b.maude"]
  end

  test "deduplicates configured and remembered modules" do
    assert :ok = Preloads.remember(:pool_a, "/configured.maude")
    assert Preloads.for_pool(:pool_a) == ["/configured.maude"]
  end

  defp restore(key, nil), do: Application.delete_env(:ex_maude, key)
  defp restore(key, value), do: Application.put_env(:ex_maude, key, value)
end
