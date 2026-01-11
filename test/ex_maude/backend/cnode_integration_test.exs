defmodule ExMaude.Backend.CNodeIntegrationTest do
  @moduledoc """
  Integration tests for C-Node backend.

  These tests require:
  1. The maude_bridge binary to be compiled (priv/maude_bridge)
  2. Maude to be installed and in PATH
  3. Erlang distribution to be enabled

  Run with: elixir --sname test -S mix test --include cnode_integration
  """
  use ExUnit.Case, async: false

  alias ExMaude.Backend

  @moduletag :cnode_integration
  @moduletag timeout: 60_000

  # Check prerequisites at module load time
  @cnode_available Backend.available?(:cnode) and Node.alive?()

  if not @cnode_available do
    setup_all do
      if not Backend.available?(:cnode) do
        IO.puts("\n⚠️  Skipping C-Node integration tests: maude_bridge not compiled")
        IO.puts("   Compile with: cd c_src && make\n")
      else
        IO.puts("\n⚠️  Skipping C-Node integration tests: distribution not enabled")
        IO.puts("   Run with: elixir --sname test -S mix test --include cnode_integration\n")
      end

      :ok
    end

    test "C-Node prerequisites not met - skipping all tests" do
      assert true
    end
  else
    alias ExMaude.Backend.CNode, warn: false

    describe "struct" do
      test "has expected fields" do
        state = %CNode{}
        assert Map.has_key?(state, :cnode_name)
        assert Map.has_key?(state, :port)
        assert Map.has_key?(state, :os_pid)
        assert Map.has_key?(state, :maude_path)
        assert Map.has_key?(state, :cookie)
        assert Map.has_key?(state, :connected)
        assert state.connected == false
      end
    end

    describe "start_link/1" do
      test "starts C-Node worker successfully" do
        assert {:ok, pid} = CNode.start_link([])
        assert Process.alive?(pid)

        connected =
          Enum.reduce_while(1..40, false, fn _i, _acc ->
            if CNode.alive?(pid) do
              {:halt, true}
            else
              Process.sleep(100)
              {:cont, false}
            end
          end)

        assert connected, "C-Node failed to connect within 4 seconds"

        CNode.stop(pid)
      end

      test "fails gracefully with invalid maude path" do
        Process.flag(:trap_exit, true)
        result = CNode.start_link(maude_path: "/nonexistent/maude")

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
        {:ok, pid} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _i, _acc ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        on_exit(fn -> catch_exit(CNode.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "executes simple reduce command", %{pid: pid} do
        assert {:ok, result} = CNode.execute(pid, "reduce in NAT : 1 + 2 .")
        assert result =~ "3"
      end

      test "handles syntax errors gracefully", %{pid: pid} do
        result = CNode.execute(pid, "reduce in NAT : 1 +")
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end

      test "handles multiple sequential commands", %{pid: pid} do
        for i <- 1..10 do
          assert {:ok, result} = CNode.execute(pid, "reduce in NAT : #{i} + #{i} .")
          assert result =~ "#{i * 2}"
        end
      end

      test "handles timeout option", %{pid: pid} do
        assert {:ok, _} = CNode.execute(pid, "reduce in NAT : 1 + 1 .", timeout: 5000)
      end
    end

    describe "load_file/2" do
      setup do
        {:ok, pid} = CNode.start_link([])

        Enum.reduce_while(1..40, false, fn _i, _acc ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        on_exit(fn -> catch_exit(CNode.stop(pid)) end)
        {:ok, pid: pid}
      end

      test "loads valid Maude file", %{pid: pid} do
        path = Path.join(System.tmp_dir!(), "test_cnode_#{:rand.uniform(10000)}.maude")
        File.write!(path, "fmod TEST-CNODE is sort Foo . endfm")
        on_exit(fn -> File.rm(path) end)

        result = CNode.load_file(pid, path)
        assert result == :ok or match?({:ok, _}, result)
      end

      test "returns error for missing file", %{pid: pid} do
        result = CNode.load_file(pid, "/nonexistent/file.maude")
        assert {:error, _} = result
      end
    end

    describe "alive?/1" do
      test "returns true for running worker" do
        {:ok, pid} = CNode.start_link([])
        Process.sleep(2000)

        assert CNode.alive?(pid)
        CNode.stop(pid)
      end

      test "returns false for stopped worker" do
        {:ok, pid} = CNode.start_link([])
        Process.sleep(1000)
        CNode.stop(pid)
        Process.sleep(100)

        refute CNode.alive?(pid)
      end
    end

    describe "stop/1" do
      test "stops the worker gracefully" do
        {:ok, pid} = CNode.start_link([])
        Process.sleep(1000)

        assert :ok = CNode.stop(pid)
        Process.sleep(100)
        refute Process.alive?(pid)
      end
    end
  end
end
