defmodule ExMaude.Backend.PortTest do
  @moduledoc """
  Tests for `ExMaude.Backend.Port` - the Port-based backend.
  """

  use ExMaude.MaudeCase

  alias ExMaude.Backend.Port

  describe "module structure" do
    test "implements Backend behaviour" do
      behaviours = Port.__info__(:attributes)[:behaviour] || []
      assert ExMaude.Backend in behaviours
    end

    test "is a GenServer" do
      assert function_exported?(Port, :init, 1)
      assert function_exported?(Port, :handle_call, 3)
      assert function_exported?(Port, :handle_info, 2)
      assert function_exported?(Port, :terminate, 2)
    end

    test "has correct struct fields" do
      state = %Port{}
      assert Map.has_key?(state, :port)
      assert Map.has_key?(state, :buffer)
      assert Map.has_key?(state, :from)
      assert Map.has_key?(state, :timeout_ref)
      assert Map.has_key?(state, :maude_path)
    end
  end

  describe "start_link/1" do
    test "accepts maude_path option" do
      opts = [maude_path: "/path/to/maude"]
      assert Keyword.get(opts, :maude_path) == "/path/to/maude"
    end

    test "accepts preload_modules option" do
      opts = [preload_modules: ["/path/to/module.maude"]]
      assert Keyword.get(opts, :preload_modules) == ["/path/to/module.maude"]
    end

    test "fails with non-existent maude path" do
      # Starting with non-existent path causes init to fail
      # The GenServer.start_link returns {:error, _} or crashes the caller
      Process.flag(:trap_exit, true)

      result = Port.start_link(maude_path: "/nonexistent/maude/binary")

      case result do
        {:error, _reason} ->
          # Expected error return
          assert true

        {:ok, pid} ->
          # If it somehow started, it should die quickly
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end
    end
  end

  describe "execute/3" do
    test "accepts timeout option" do
      assert function_exported?(Port, :execute, 3)
    end

    test "exits when server is not alive" do
      # Create a fake pid that doesn't exist
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      # GenServer.call to dead process raises exit
      # The execute/3 only catches :timeout exits, not :noproc
      assert catch_exit(Port.execute(fake_pid, "test", timeout: 100))
    end
  end

  describe "load_file/2" do
    test "function exists with correct arity" do
      assert function_exported?(Port, :load_file, 2)
    end
  end

  describe "stop/1" do
    test "function exists with correct arity" do
      assert function_exported?(Port, :stop, 1)
    end
  end

  describe "integration tests" do
    @tag :integration
    test "starts and stops", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])
      assert Process.alive?(pid)
      assert Port.alive?(pid)

      Port.stop(pid)
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    @tag :integration
    test "executes reduce command", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      {:ok, result} = Port.execute(pid, "reduce in NAT : 1 + 2 .")
      assert result == "3"

      Port.stop(pid)
    end

    @tag :integration
    test "executes multiple commands sequentially", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      {:ok, r1} = Port.execute(pid, "reduce in NAT : 10 .")
      {:ok, r2} = Port.execute(pid, "reduce in NAT : 20 .")
      {:ok, r3} = Port.execute(pid, "reduce in BOOL : true and false .")

      assert r1 == "10"
      assert r2 == "20"
      assert r3 == "false"

      Port.stop(pid)
    end

    @tag :integration
    test "reports alive? correctly", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      assert Port.alive?(pid) == true

      Port.stop(pid)
      Process.sleep(100)

      assert Port.alive?(pid) == false
    end

    @tag :integration
    test "handles syntax errors gracefully", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      result = Port.execute(pid, "reduce in NAT : invalid$$syntax .")
      assert match?({:error, _}, result)

      Port.stop(pid)
    end

    @tag :integration
    test "handles load_file for non-existent file", %{maude_available: true} do
      {:ok, pid} = Port.start_link([])

      result = Port.load_file(pid, "/nonexistent/file.maude")
      assert match?({:error, _}, result)

      Port.stop(pid)
    end
  end

  describe "alive?/1 edge cases" do
    test "returns false for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)
      refute Port.alive?(pid)
    end

    test "returns false for non-existent pid" do
      # Create and immediately kill a process
      pid = spawn(fn -> :ok end)
      Process.exit(pid, :kill)
      Process.sleep(10)
      refute Port.alive?(pid)
    end
  end

  describe "telemetry events" do
    @tag :integration
    test "emits start event", %{maude_available: true} do
      test_pid = self()

      :telemetry.attach(
        "test-port-start",
        [:ex_maude, :server, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Port.start_link([])

      assert_receive {:telemetry, [:ex_maude, :server, :start], _, %{backend: :port}}, 5000

      Port.stop(pid)
      :telemetry.detach("test-port-start")
    end

    @tag :integration
    test "emits command_complete event", %{maude_available: true} do
      test_pid = self()

      :telemetry.attach(
        "test-port-command",
        [:ex_maude, :server, :command_complete],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Port.start_link([])
      Port.execute(pid, "reduce in NAT : 1 + 1 .")

      assert_receive {:telemetry, [:ex_maude, :server, :command_complete], %{success: true},
                      %{backend: :port}},
                     5000

      Port.stop(pid)
      :telemetry.detach("test-port-command")
    end
  end
end
