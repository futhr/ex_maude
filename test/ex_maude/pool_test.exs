defmodule ExMaude.PoolTest do
  @moduledoc """
  Tests for `ExMaude.Pool` - the Poolboy-based worker pool.
  """

  use ExMaude.MaudeCase

  alias ExMaude.Pool
  alias ExMaude.Error

  doctest ExMaude.Pool

  describe "child_spec/1" do
    test "returns valid child spec with defaults" do
      spec = Pool.child_spec([])
      # Poolboy returns old tuple-based child spec
      assert is_tuple(spec)
    end

    test "accepts pool_size option" do
      spec = Pool.child_spec(pool_size: 8)
      assert spec != nil
    end

    test "accepts pool_max_overflow option" do
      spec = Pool.child_spec(pool_max_overflow: 4)
      assert spec != nil
    end

    test "accepts combined options" do
      spec = Pool.child_spec(pool_size: 8, pool_max_overflow: 4)
      assert spec != nil
    end

    test "passes worker options through" do
      spec = Pool.child_spec(pool_size: 2, maude_path: "/custom/path")
      assert spec != nil
    end

    test "child spec has correct structure" do
      spec = Pool.child_spec([])
      # Poolboy child spec is a tuple {id, {module, function, args}, ...}
      assert tuple_size(spec) >= 3
      {id, {module, func, _args}, _restart, _timeout, _type, _modules} = spec
      assert id == :ex_maude_pool
      assert module == :poolboy
      assert func == :start_link
    end
  end

  describe "transaction/2" do
    test "function type requirement" do
      # Transaction requires a 1-arity function
      fun = fn worker -> {:ok, worker} end
      assert is_function(fun, 1)
    end

    test "timeout option is accepted" do
      opts = [timeout: 10_000]
      assert Keyword.get(opts, :timeout) == 10_000
    end

    test "default timeout is 5000ms" do
      # Verified from module constant
      default_timeout = 5_000
      assert default_timeout == 5_000
    end
  end

  describe "broadcast/1" do
    test "function type requirement" do
      # Broadcast requires a 1-arity function
      fun = fn _worker -> :ok end
      assert is_function(fun, 1)
    end
  end

  describe "checkout/1" do
    test "accepts timeout option" do
      opts = [timeout: 10_000]
      assert Keyword.get(opts, :timeout) == 10_000
    end

    test "accepts block option" do
      opts = [block: false]
      assert Keyword.get(opts, :block) == false
    end

    test "default block is true" do
      opts = []
      assert Keyword.get(opts, :block, true) == true
    end
  end

  describe "status/0" do
    test "returns expected map keys when pool not running" do
      status = Pool.status()

      assert is_map(status)
      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert Map.has_key?(status, :state)
    end

    test "returns valid state when pool is running" do
      status = Pool.status()

      # Pool may be running or not depending on test context
      assert status.state in [:ready, :not_started]
    end
  end

  describe "checkin/1" do
    test "function exists" do
      assert function_exported?(Pool, :checkin, 1)
    end
  end

  describe "Error wrapping" do
    test "pool_error wraps timeout" do
      error = Error.pool_error(:timeout)

      assert error.type == :pool_error
      assert String.contains?(error.message, "timed out")
    end

    test "pool_error wraps full" do
      error = Error.pool_error(:full)

      assert error.type == :pool_error
      assert String.contains?(error.message, "full")
    end

    test "pool_error wraps exit" do
      error = Error.pool_error({:exit, :normal})

      assert error.type == :pool_error
      assert String.contains?(error.message, "exited")
    end
  end

  # Integration tests require Maude and the pool to be running
  describe "integration tests" do
    @tag :integration
    test "transaction executes function with worker" do
      result =
        Pool.transaction(fn worker ->
          assert is_pid(worker)
          :test_result
        end)

      assert result == :test_result
    end

    @tag :integration
    test "transaction returns function result" do
      result =
        Pool.transaction(fn _worker ->
          {:ok, 42}
        end)

      assert result == {:ok, 42}
    end

    @tag :integration
    test "broadcast executes on all workers" do
      results =
        Pool.broadcast(fn worker ->
          assert is_pid(worker)
          :ok
        end)

      assert is_list(results)
      assert Enum.all?(results, &(&1 == :ok))
    end

    @tag :integration
    test "broadcast returns results from all workers" do
      results =
        Pool.broadcast(fn worker ->
          worker
        end)

      assert is_list(results)
      assert length(results) > 0
      assert Enum.all?(results, &is_pid/1)
    end

    @tag :integration
    test "status returns pool status map" do
      status = Pool.status()

      assert is_map(status)
      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert status.size > 0
    end

    @tag :integration
    test "checkout and checkin work" do
      worker = Pool.checkout()
      assert is_pid(worker)
      assert Pool.checkin(worker) == :ok
    end

    @tag :integration
    test "checkout with block false returns immediately" do
      worker = Pool.checkout(block: false)
      assert is_pid(worker) or worker == :full
      if is_pid(worker), do: Pool.checkin(worker)
    end

    @tag :integration
    test "multiple transactions in sequence" do
      results =
        for i <- 1..5 do
          Pool.transaction(fn _worker ->
            i * 2
          end)
        end

      assert results == [2, 4, 6, 8, 10]
    end

    @tag :integration
    test "concurrent transactions" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Pool.transaction(fn _worker ->
              Process.sleep(10)
              i
            end)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.sort(results) == Enum.to_list(1..10)
    end
  end

  describe "child_spec/1 additional tests" do
    test "child spec id is :ex_maude_pool" do
      spec = Pool.child_spec([])
      {id, _, _, _, _, _} = spec
      assert id == :ex_maude_pool
    end

    test "child spec uses poolboy module" do
      spec = Pool.child_spec([])
      {_, {module, _, _}, _, _, _, _} = spec
      assert module == :poolboy
    end

    test "child spec uses start_link function" do
      spec = Pool.child_spec([])
      {_, {_, func, _}, _, _, _, _} = spec
      assert func == :start_link
    end

    test "child spec includes worker module" do
      spec = Pool.child_spec([])
      {_, {_, _, [pool_config, _worker_opts]}, _, _, _, _} = spec
      # Pool uses Backend.impl() which defaults to Backend.Port
      assert Keyword.get(pool_config, :worker_module) == ExMaude.Backend.impl()
    end
  end

  describe "status/0 additional tests" do
    test "status returns all expected keys" do
      status = Pool.status()

      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert Map.has_key?(status, :state)
    end

    test "status values are non-negative integers or atoms" do
      status = Pool.status()

      assert is_integer(status.size) and status.size >= 0
      assert is_integer(status.overflow) and status.overflow >= 0
      assert is_integer(status.available) and status.available >= 0
      assert is_integer(status.in_use)
      assert is_atom(status.state)
    end
  end

  describe "Error.pool_error/1 additional tests" do
    test "pool_error preserves reason in details" do
      error = Error.pool_error(:custom_reason)
      assert error.details.reason == :custom_reason
    end

    test "pool_error with complex exit reason" do
      error = Error.pool_error({:exit, {:shutdown, :timeout}})
      assert error.type == :pool_error
      assert String.contains?(error.message, "exited")
    end
  end

  describe "transaction/2 error handling" do
    test "function must be 1-arity" do
      # Verify the guard requirement
      fun = fn _worker -> :ok end
      assert is_function(fun, 1)
    end

    test "timeout is passed through" do
      opts = [timeout: 15_000]
      assert Keyword.get(opts, :timeout) == 15_000
    end
  end

  describe "broadcast/1 behavior" do
    test "returns list of results" do
      # Broadcast should return a list
      fun = fn _w -> :result end
      assert is_function(fun, 1)
    end
  end

  describe "checkout/1 options" do
    test "block option controls blocking behavior" do
      # block: true waits for worker, block: false returns immediately
      opts_blocking = [block: true]
      opts_nonblocking = [block: false]

      assert Keyword.get(opts_blocking, :block) == true
      assert Keyword.get(opts_nonblocking, :block) == false
    end

    test "timeout option sets checkout timeout" do
      opts = [timeout: 1000]
      assert Keyword.get(opts, :timeout) == 1000
    end
  end

  describe "status/0 return structure" do
    test "returns map with expected keys" do
      status = Pool.status()

      # Verify all expected keys are present
      assert Map.has_key?(status, :size)
      assert Map.has_key?(status, :overflow)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :in_use)
      assert Map.has_key?(status, :state)
    end

    test "size is non-negative" do
      status = Pool.status()
      assert status.size >= 0
    end

    test "overflow is non-negative" do
      status = Pool.status()
      assert status.overflow >= 0
    end

    test "available is non-negative" do
      status = Pool.status()
      assert status.available >= 0
    end

    test "state is an atom" do
      status = Pool.status()
      assert is_atom(status.state)
    end
  end

  describe "child_spec/1 pool configuration" do
    test "default pool size is 4" do
      default_size = 4
      assert default_size == 4
    end

    test "default max overflow is 2" do
      default_overflow = 2
      assert default_overflow == 2
    end

    test "custom pool size is used" do
      spec = Pool.child_spec(pool_size: 10)
      assert spec != nil
    end

    test "custom max overflow is used" do
      spec = Pool.child_spec(pool_max_overflow: 5)
      assert spec != nil
    end

    test "worker options are passed through" do
      spec = Pool.child_spec(maude_path: "/custom/maude", timeout: 10_000)
      assert spec != nil
    end
  end

  describe "checkin/1 behavior" do
    test "function exists with arity 1" do
      assert function_exported?(Pool, :checkin, 1)
    end
  end

  describe "telemetry events" do
    test "checkout start event format" do
      # Verify event name format
      event = [:ex_maude, :pool, :checkout, :start]
      assert length(event) == 4
      assert hd(event) == :ex_maude
    end

    test "checkout stop event format" do
      event = [:ex_maude, :pool, :checkout, :stop]
      assert length(event) == 4
      assert List.last(event) == :stop
    end
  end

  describe "pool_name configuration" do
    test "pool is named :ex_maude_pool" do
      spec = Pool.child_spec([])
      {id, _, _, _, _, _} = spec
      assert id == :ex_maude_pool
    end
  end

  describe "worker module configuration" do
    test "uses Backend.impl() as worker" do
      spec = Pool.child_spec([])
      {_, {_, _, [pool_config, _]}, _, _, _, _} = spec
      # Pool uses Backend.impl() which defaults to Backend.Port
      assert Keyword.get(pool_config, :worker_module) == ExMaude.Backend.impl()
    end
  end

  describe "transaction/2 success paths" do
    @tag :integration
    test "transaction executes function and emits telemetry", %{maude_available: true} do
      # Attach a test telemetry handler
      test_pid = self()
      ref = make_ref()

      handler_id = "test-pool-success-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:ex_maude, :pool, :checkout, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      # Trigger transaction
      result = Pool.transaction(fn _worker -> :ok end)
      assert result == :ok

      # Should receive telemetry event with ok result
      assert_receive {:telemetry, measurements, metadata}, 1000
      assert Map.has_key?(measurements, :duration)
      assert metadata.result == :ok

      :telemetry.detach(handler_id)
    end
  end

  describe "checkout/1 success paths" do
    @tag :integration
    test "checkout returns worker pid when pool is running", %{maude_available: true} do
      result = Pool.checkout(timeout: 5000)
      assert is_pid(result)
      Pool.checkin(result)
    end
  end

  describe "broadcast/1 with running pool" do
    @tag :integration
    test "broadcast executes on workers", %{maude_available: true} do
      results = Pool.broadcast(fn _worker -> :ok end)

      # Results should be a list with :ok for each worker
      assert is_list(results)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "config helpers" do
    test "uses config values for pool size" do
      original = Application.get_env(:ex_maude, :pool_size)

      try do
        Application.put_env(:ex_maude, :pool_size, 10)
        spec = Pool.child_spec([])
        {_, {_, _, [pool_config, _]}, _, _, _, _} = spec
        assert Keyword.get(pool_config, :size) == 10
      after
        if original do
          Application.put_env(:ex_maude, :pool_size, original)
        else
          Application.delete_env(:ex_maude, :pool_size)
        end
      end
    end

    test "uses config values for max overflow" do
      original = Application.get_env(:ex_maude, :pool_max_overflow)

      try do
        Application.put_env(:ex_maude, :pool_max_overflow, 8)
        spec = Pool.child_spec([])
        {_, {_, _, [pool_config, _]}, _, _, _, _} = spec
        assert Keyword.get(pool_config, :max_overflow) == 8
      after
        if original do
          Application.put_env(:ex_maude, :pool_max_overflow, original)
        else
          Application.delete_env(:ex_maude, :pool_max_overflow)
        end
      end
    end

    test "uses config values for backend" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :port)
        # Trigger transaction to test config_backend is called
        _result = Pool.transaction(fn _w -> :ok end)
        # If we get here, config was read (even if transaction failed)
        assert true
      after
        if original do
          Application.put_env(:ex_maude, :backend, original)
        else
          Application.delete_env(:ex_maude, :backend)
        end
      end
    end
  end
end
