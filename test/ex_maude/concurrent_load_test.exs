defmodule ExMaude.ConcurrentLoadTest do
  @moduledoc """
  Regression cover for the concurrent-load stampede.

  Before `ensure_file_loaded/2`, every `detect_conflicts/2` call broadcast a
  file load to every pool worker — including workers checked out serving other
  reductions. Twelve concurrent callers produced eleven
  `load_error: Partial load: N module(s) failed to load` results and one
  success. The gate failed closed, which is correct behaviour for a wrong
  answer, but the library was manufacturing the failure itself.
  """
  use ExMaude.MaudeCase, async: false

  @moduletag :integration

  alias ExMaude.Maude

  setup do
    pool = :concurrent_load_test_pool
    start_supervised!(ExMaude.Pool.child_spec(name: pool, pool_size: 4))
    %{pool: pool}
  end

  @rules [
    %{
      id: "a",
      thing_id: "device-1",
      trigger: {:prop_lt, "battery", 20},
      actions: [{:set_prop, "device-1", "destination", "dock-7"}],
      priority: 1
    },
    %{
      id: "b",
      thing_id: "device-1",
      trigger: {:prop_gte, "hour", 9},
      actions: [{:set_prop, "device-1", "destination", "dock-19"}],
      priority: 1
    }
  ]

  describe "ensure_file_loaded/2" do
    test "is idempotent", %{pool: pool} do
      path = ExMaude.iot_rules_path()

      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
      assert :ok = Maude.ensure_file_loaded(path, pool: pool)
    end

    test "reports a missing file rather than pretending to load it" do
      assert {:error, %ExMaude.Error{}} =
               Maude.ensure_file_loaded("/nonexistent/definitely-not-here.maude")
    end

    test "concurrent first-callers all succeed", %{pool: pool} do
      path = ExMaude.iot_rules_path()

      results =
        1..16
        |> Task.async_stream(fn _ -> Maude.ensure_file_loaded(path, pool: pool) end,
          max_concurrency: 16,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok)),
             "expected every concurrent load to succeed, got: #{inspect(Enum.frequencies(results))}"
    end
  end

  describe "detect_conflicts/2 under concurrency" do
    test "every concurrent caller gets the same real answer", %{pool: pool} do
      # Warm the pool once, the way an application does at boot (or via
      # `:preload_modules`). What is being tested is that the *steady state* no
      # longer re-broadcasts a load per call and trips over its own workers.
      :ok = Maude.ensure_file_loaded(ExMaude.iot_rules_path(), pool: pool)

      results =
        1..12
        |> Task.async_stream(fn _ -> ExMaude.IoT.detect_conflicts(@rules, pool: pool) end,
          max_concurrency: 8,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      failures = Enum.reject(results, &match?({:ok, _}, &1))

      assert failures == [],
             "concurrent detection must not manufacture load errors, got: #{inspect(failures)}"

      # And the answer must be right, not merely non-failing.
      Enum.each(results, fn {:ok, conflicts} ->
        assert [%{type: :state_conflict, rule1: "a", rule2: "b"}] =
                 Enum.map(conflicts, &Map.take(&1, [:type, :rule1, :rule2]))
      end)
    end
  end
end
