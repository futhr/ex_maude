defmodule ExMaude.Backend.NIFIntegrationTest do
  @moduledoc """
  Integration tests for NIF backend.

  These tests require:
  1. The Rustler NIF to be compiled
  2. Maude to be installed and in PATH
  3. Rust toolchain installed

  Run with: mix test --include nif_integration
  """
  use ExUnit.Case, async: false

  alias ExMaude.Backend

  @moduletag :nif_integration
  @moduletag timeout: 60_000

  # Check prerequisites at module load time
  @nif_available Backend.available?(:nif)

  if not @nif_available do
    setup_all do
      IO.puts("\n⚠️  Skipping NIF tests: Rustler NIF not compiled or not loaded")
      IO.puts("   Ensure Rust is installed and run: mix compile\n")
      :ok
    end

    test "NIF prerequisites not met - skipping all tests" do
      assert true
    end
  else
    alias ExMaude.Backend.NIF

    describe "struct" do
      test "has expected fields" do
        state = %NIF{}
        assert Map.has_key?(state, :handle)
        assert Map.has_key?(state, :maude_path)
        assert Map.has_key?(state, :initialized)
        assert state.initialized == false
      end
    end

    describe "start_link/1" do
      test "starts NIF worker successfully" do
        assert {:ok, pid} = NIF.start_link([])
        assert Process.alive?(pid)
        assert NIF.alive?(pid)

        NIF.stop(pid)
      end

      test "fails gracefully with invalid maude path" do
        Process.flag(:trap_exit, true)
        result = NIF.start_link(maude_path: "/nonexistent/maude")

        case result do
          {:error, _} ->
            assert true

          {:ok, pid} ->
            assert_receive {:EXIT, ^pid, _reason}, 5000
        end
      end
    end

    describe "execute/3" do
      setup do
        {:ok, pid} = NIF.start_link([])
        on_exit(fn -> catch_exit(NIF.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "executes simple reduce command", %{pid: pid} do
        assert {:ok, result} = NIF.execute(pid, "reduce in NAT : 1 + 2 .")
        assert result =~ "3"
      end

      test "handles syntax errors gracefully", %{pid: pid} do
        result = NIF.execute(pid, "reduce in NAT : 1 +")
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end

      test "handles multiple sequential commands", %{pid: pid} do
        for i <- 1..10 do
          assert {:ok, result} = NIF.execute(pid, "reduce in NAT : #{i} + #{i} .")
          assert result =~ "#{i * 2}"
        end
      end

      test "handles timeout option", %{pid: pid} do
        assert {:ok, _} = NIF.execute(pid, "reduce in NAT : 1 + 1 .", timeout: 5000)
      end
    end

    describe "load_file/2" do
      setup do
        {:ok, pid} = NIF.start_link([])
        on_exit(fn -> catch_exit(NIF.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "loads valid Maude file", %{pid: pid} do
        path = Path.join(System.tmp_dir!(), "test_nif_#{:rand.uniform(10000)}.maude")
        File.write!(path, "fmod TEST-NIF is sort Foo . endfm")
        on_exit(fn -> File.rm(path) end)

        result = NIF.load_file(pid, path)
        assert result == :ok or match?({:ok, _}, result)
      end

      test "returns error for missing file", %{pid: pid} do
        result = NIF.load_file(pid, "/nonexistent/file.maude")
        assert {:error, _} = result
      end
    end

    describe "alive?/1" do
      test "returns true for running worker" do
        {:ok, pid} = NIF.start_link([])
        assert NIF.alive?(pid)
        NIF.stop(pid)
      end

      test "returns false for stopped worker" do
        {:ok, pid} = NIF.start_link([])
        NIF.stop(pid)
        Process.sleep(100)

        refute NIF.alive?(pid)
      end
    end

    describe "stop/1" do
      test "stops the worker gracefully" do
        {:ok, pid} = NIF.start_link([])

        assert :ok = NIF.stop(pid)
        Process.sleep(100)
        refute Process.alive?(pid)
      end
    end
  end
end
