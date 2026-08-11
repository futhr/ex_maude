defmodule ExMaude.Backend.NIFLifecycleTest do
  @moduledoc """
  Tests NIF backend timeout and EOF restart semantics with protocol-compatible
  fake Maude executables.

  The NIF only needs an executable that speaks the prompt protocol, so these
  cases do not require a real Maude installation. They do require the compiled
  NIF, hence the module tags.
  """

  use ExMaude.NIFCase, async: false

  @moduletag :nif
  @moduletag :integration

  alias ExMaude.Backend.NIF
  alias ExMaude.Error

  @fake_maude Path.expand("../../support/fake_maude.sh", __DIR__)
  @fake_silent Path.expand("../../support/fake_silent.sh", __DIR__)

  defp start_fake_worker do
    start_supervised!({NIF, maude_path: @fake_maude}, restart: :temporary)
  end

  describe "native timeout" do
    test "replies with a timeout error and stops the worker" do
      pid = start_fake_worker()
      ref = Process.monitor(pid)

      assert {:error, %Error{type: :timeout} = error} =
               NIF.execute(pid, "hang", timeout: 80)

      assert error.details.timeout_ms == 80

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:native_failure, :timeout}}},
                     1_000
    end

    test "emits a timeout telemetry event" do
      handler_id = "nif-lifecycle-timeout-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ex_maude, :server, :timeout],
        fn _, measurements, metadata, _ ->
          send(test_pid, {:timeout_event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_fake_worker()
      NIF.execute(pid, "hang", timeout: 60)

      assert_receive {:timeout_event, %{timeout_ms: 60}, %{backend: :nif}}, 1_000
    end
  end

  describe "native EOF" do
    test "a crashed interpreter stops the worker with a crash error" do
      pid = start_fake_worker()
      ref = Process.monitor(pid)

      assert {:error, %Error{type: :maude_crash}} = NIF.execute(pid, "die", timeout: 1_000)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:native_failure, :maude_crash}}},
                     1_000
    end
  end

  describe "native process ownership" do
    test "failed startup kills and reaps the spawned process" do
      assert {:error, {:timeout, 100}} = NIF.Native.start_with_timeout(@fake_silent, 100)
      os_pid = NIF.Native.last_spawned_pid()
      os_pid = Integer.to_string(os_pid)
      assert_process_gone(os_pid)
    end

    test "dropping the final resource reference reaps the child" do
      handle = NIF.Native.start(@fake_maude)
      os_pid = NIF.Native.child_pid(handle)
      os_pid = Integer.to_string(os_pid)

      handle = nil
      assert is_nil(handle)
      :erlang.garbage_collect(self())
      assert_process_gone(os_pid)
    end
  end

  describe "response isolation across worker restarts" do
    test "a command after a timeout never receives the timed-out command's output" do
      pool_name = :nif_lifecycle_pool

      {:ok, pool} =
        :poolboy.start_link(
          [name: {:local, pool_name}, worker_module: NIF, size: 1, max_overflow: 0],
          maude_path: @fake_maude
        )

      {worker_ref, {:error, %Error{type: :timeout}}} =
        :poolboy.transaction(pool_name, fn worker ->
          {Process.monitor(worker), NIF.execute(worker, "hang", timeout: 50)}
        end)

      assert_receive {:DOWN, ^worker_ref, :process, _, {:shutdown, {:native_failure, :timeout}}},
                     1_000

      wait_for_available_worker(pool_name)

      assert {:ok, response} =
               :poolboy.transaction(pool_name, fn worker ->
                 NIF.execute(worker, "marker-b", timeout: 1_000)
               end)

      assert response =~ "marker-b"
      refute response =~ "hang"

      :poolboy.stop(pool)
    end
  end

  describe "semantic Maude errors" do
    test "a parse-level error keeps the worker alive" do
      pid = start_fake_worker()
      ref = Process.monitor(pid)

      # The fake echoes the command; "Warning: ..." in the echoed payload is
      # classified as a Maude error by the parser, not a native failure.
      assert {:error, %Error{}} = NIF.execute(pid, "Warning: no module FOO", timeout: 1_000)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert NIF.alive?(pid)
    end
  end

  defp wait_for_available_worker(pool_name, attempts \\ 100) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case :poolboy.status(pool_name) do
        {:ready, available, _, _} when available > 0 ->
          {:halt, :ok}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end) || flunk("pool never recovered an available worker")
  end

  defp assert_process_gone(os_pid) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(10)
          {:cont, nil}

        _ ->
          {:halt, :ok}
      end
    end) || flunk("native Maude process #{os_pid} was not reaped")
  end
end
