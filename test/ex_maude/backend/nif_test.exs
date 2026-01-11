defmodule ExMaude.Backend.NIFTest do
  @moduledoc """
  Tests for `ExMaude.Backend.NIF` - the NIF-based backend stub.

  This backend is a Phase 3 stub that will eventually provide direct
  native integration with libmaude via Rustler. Currently, all operations
  return `{:error, :not_implemented}`.

  ## Test Categories

    * Module structure - Verifies behaviour implementation
    * Stub behavior - Ensures stub returns expected errors
    * Future integration - Placeholder for when NIF is implemented

  ## Running Tests

  These tests run without any native code requirements since the NIF
  backend is currently a stub.
  """

  use ExUnit.Case, async: true

  alias ExMaude.Backend
  alias ExMaude.Backend.NIF

  describe "module structure" do
    setup do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(NIF)
      :ok
    end

    test "implements Backend behaviour" do
      behaviours = NIF.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(NIF, :init, 1)
      assert function_exported?(NIF, :handle_call, 3)
      assert function_exported?(NIF, :handle_info, 2)
      assert function_exported?(NIF, :terminate, 2)
    end

    test "exports all Backend callbacks" do
      assert function_exported?(NIF, :start_link, 1)
      assert function_exported?(NIF, :execute, 3)
      assert function_exported?(NIF, :alive?, 1)
      assert function_exported?(NIF, :load_file, 2)
      assert function_exported?(NIF, :stop, 1)
    end
  end

  describe "start_link/1" do
    test "accepts maude_path option" do
      opts = [maude_path: "/path/to/maude"]
      assert Keyword.get(opts, :maude_path) == "/path/to/maude"
    end

    test "starts successfully as stub" do
      {:ok, pid} = NIF.start_link([])
      assert Process.alive?(pid)
      NIF.stop(pid)
    end
  end

  describe "stub behavior" do
    setup do
      {:ok, pid} = NIF.start_link([])
      on_exit(fn -> catch_exit(NIF.stop(pid)) end)
      {:ok, server: pid}
    end

    test "alive? returns false (not initialized)", %{server: pid} do
      # Stub is not initialized since native module isn't loaded
      refute NIF.alive?(pid)
    end

    test "execute returns not_implemented error", %{server: pid} do
      result = NIF.execute(pid, "reduce in NAT : 1 + 1 .")

      assert {:error, error} = result
      assert error.type == :not_implemented
      assert String.contains?(error.message, "not yet implemented")
    end

    test "load_file returns not_implemented error", %{server: pid} do
      result = NIF.load_file(pid, "/path/to/file.maude")

      assert {:error, error} = result
      assert error.type == :not_implemented
    end
  end

  describe "availability" do
    test "available? returns false (native not loaded)" do
      # Until the native Rustler module is implemented
      refute Backend.available?(:nif)
    end
  end

  describe "alive?/1 edge cases" do
    test "returns false for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute NIF.alive?(pid)
    end

    test "returns false for non-existent pid" do
      pid = spawn(fn -> :ok end)
      Process.exit(pid, :kill)
      Process.sleep(10)
      refute NIF.alive?(pid)
    end
  end

  describe "configuration" do
    test "impl returns NIF when configured" do
      original = Application.get_env(:ex_maude, :backend)

      try do
        Application.put_env(:ex_maude, :backend, :nif)
        assert Backend.impl() == ExMaude.Backend.NIF
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
