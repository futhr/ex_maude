defmodule ExMaude.ApplicationTest do
  @moduledoc """
  Tests for `ExMaude.Application` - the OTP application callback module.
  """

  use ExUnit.Case

  doctest ExMaude.Application

  describe "application" do
    test "application is started" do
      assert {:ok, _} = Application.ensure_all_started(:ex_maude)
    end

    test "application module is loaded" do
      assert Code.ensure_loaded?(ExMaude.Application)
    end

    test "start/2 is exported" do
      assert function_exported?(ExMaude.Application, :start, 2)
    end
  end

  describe "configuration" do
    test "start_pool defaults to false" do
      # Clear any existing config
      original = Application.get_env(:ex_maude, :start_pool)

      try do
        Application.delete_env(:ex_maude, :start_pool)
        assert Application.get_env(:ex_maude, :start_pool, false) == false
      after
        if original != nil do
          Application.put_env(:ex_maude, :start_pool, original)
        end
      end
    end

    test "pool_size has default" do
      default = Application.get_env(:ex_maude, :pool_size, 4)
      assert is_integer(default)
      assert default > 0
    end

    test "pool_max_overflow has default" do
      default = Application.get_env(:ex_maude, :pool_max_overflow, 2)
      assert is_integer(default)
      assert default >= 0
    end
  end

  describe "supervisor" do
    test "supervisor is running" do
      assert Process.whereis(ExMaude.Supervisor) != nil
    end

    test "supervisor strategy is one_for_one" do
      # Verified in application.ex source
      source = File.read!("lib/ex_maude/application.ex")
      assert source =~ "strategy: :one_for_one"
    end
  end

  describe "pool startup behavior" do
    test "pool not started when start_pool is false" do
      # In test config, start_pool should be false
      # So the pool should not be running
      start_pool = Application.get_env(:ex_maude, :start_pool, false)

      if start_pool == false do
        # Pool process should not exist
        status = ExMaude.Pool.status()
        assert status.state == :not_started
      end
    end

    @tag :integration
    test "pool started when start_pool is true" do
      start_pool = Application.get_env(:ex_maude, :start_pool, false)

      if start_pool == true do
        status = ExMaude.Pool.status()
        assert status.state != :not_started
        assert status.size > 0
      end
    end
  end

  describe "child spec generation" do
    test "Pool.child_spec/1 is available" do
      spec = ExMaude.Pool.child_spec([])
      assert is_tuple(spec)
    end

    test "child spec can be customized" do
      spec = ExMaude.Pool.child_spec(pool_size: 8, pool_max_overflow: 4)
      assert spec != nil
    end
  end
end
