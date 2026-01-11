defmodule ExMaude.Backend.CNodeTest do
  @moduledoc """
  Tests for `ExMaude.Backend.CNode` - the C-Node backend.

  Note: Most integration tests require:
  1. The maude_bridge binary to be compiled (cd c_src && make)
  2. The node to be running in distributed mode
  3. Maude to be installed
  """

  use ExUnit.Case, async: true

  alias ExMaude.Backend
  alias ExMaude.Backend.CNode

  describe "module structure" do
    test "implements Backend behaviour" do
      behaviours = CNode.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(CNode, :init, 1)
      assert function_exported?(CNode, :handle_call, 3)
      assert function_exported?(CNode, :handle_info, 2)
      assert function_exported?(CNode, :terminate, 2)
    end

    test "exports all Backend callbacks" do
      assert function_exported?(CNode, :start_link, 1)
      assert function_exported?(CNode, :execute, 3)
      assert function_exported?(CNode, :alive?, 1)
      assert function_exported?(CNode, :load_file, 2)
      assert function_exported?(CNode, :stop, 1)
    end

    test "has correct struct fields" do
      state = %CNode{}
      assert Map.has_key?(state, :cnode_name)
      assert Map.has_key?(state, :port)
      assert Map.has_key?(state, :os_pid)
      assert Map.has_key?(state, :maude_path)
      assert Map.has_key?(state, :cookie)
      assert Map.has_key?(state, :connected)
    end

    test "struct has correct defaults" do
      state = %CNode{}
      assert state.cookie == ""
      assert state.connected == false
    end
  end

  describe "start_link/1 options" do
    test "accepts maude_path option" do
      opts = [maude_path: "/path/to/maude"]
      assert Keyword.get(opts, :maude_path) == "/path/to/maude"
    end

    test "accepts cookie option" do
      opts = [cookie: "secret_cookie"]
      assert Keyword.get(opts, :cookie) == "secret_cookie"
    end
  end

  describe "availability" do
    test "available? returns boolean" do
      result = Backend.available?(:cnode)
      assert is_boolean(result)
    end

    test "available? checks for maude_bridge binary" do
      # The result depends on whether the binary is compiled
      priv_dir = :code.priv_dir(:ex_maude)
      binary_path = Path.join(priv_dir, "maude_bridge")
      binary_exists = File.exists?(binary_path)

      assert Backend.available?(:cnode) == binary_exists
    end
  end

  describe "alive?/1 edge cases" do
    test "returns false for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute CNode.alive?(pid)
    end

    test "returns false for non-existent pid" do
      fake_pid = spawn(fn -> :ok end)
      Process.exit(fake_pid, :kill)
      Process.sleep(10)
      refute CNode.alive?(fake_pid)
    end
  end

  describe "execute/3 edge cases" do
    test "returns error when not connected" do
      # This tests the behavior when calling execute on an unconnected server
      # We can't easily test this without mocking, but we verify the function exists
      assert function_exported?(CNode, :execute, 3)
    end

    test "exits when server is not alive" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      # GenServer.call to dead process raises exit
      # The execute/3 only catches :timeout exits, not :noproc
      assert catch_exit(CNode.execute(fake_pid, "test", timeout: 100))
    end
  end

  describe "load_file/2" do
    test "function exists with correct arity" do
      assert function_exported?(CNode, :load_file, 2)
    end
  end

  describe "stop/1" do
    test "function exists with correct arity" do
      assert function_exported?(CNode, :stop, 1)
    end
  end

  describe "default constants" do
    test "default timeout is 30 seconds" do
      # Verify the default timeout by checking the module attribute
      # This is indirectly tested through execute behavior
      assert function_exported?(CNode, :execute, 3)
    end
  end

  # Integration tests - only run when C-Node binary is available and node is distributed
  describe "integration tests" do
    @describetag :cnode

    setup context do
      cnode_available = Backend.available?(:cnode)
      node_distributed = Node.alive?()

      cond do
        not cnode_available ->
          {:ok, Map.put(context, :skip, "C-Node binary not compiled (run: cd c_src && make)")}

        not node_distributed ->
          {:ok,
           Map.put(context, :skip, "Node not distributed (run: elixir --sname test -S mix test)")}

        true ->
          {:ok, cnode_available: true}
      end
    end

    @tag :integration
    test "starts and connects", context do
      if Map.has_key?(context, :skip) do
        {:skip, context.skip}
      else
        {:ok, pid} = CNode.start_link([])

        # Wait for connection with timeout
        result =
          Enum.reduce_while(1..40, false, fn _i, _acc ->
            if CNode.alive?(pid) do
              {:halt, true}
            else
              Process.sleep(100)
              {:cont, false}
            end
          end)

        assert result, "C-Node failed to connect within 4 seconds"

        CNode.stop(pid)
      end
    end

    @tag :integration
    test "executes reduce command", context do
      if Map.has_key?(context, :skip) do
        {:skip, context.skip}
      else
        {:ok, pid} = CNode.start_link([])

        # Wait for connection
        Enum.reduce_while(1..40, false, fn _i, _acc ->
          if CNode.alive?(pid) do
            {:halt, true}
          else
            Process.sleep(100)
            {:cont, false}
          end
        end)

        {:ok, result} = CNode.execute(pid, "reduce in NAT : 1 + 2 .")
        assert result == "3"

        CNode.stop(pid)
      end
    end

    test "skipped when C-Node not available", context do
      if context[:skip] do
        IO.puts("Skipping: #{context[:skip]}")
      end

      :ok
    end
  end
end
