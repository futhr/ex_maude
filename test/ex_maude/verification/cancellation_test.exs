defmodule ExMaude.Verification.CancellationTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ExMaude.Error
  alias ExMaude.Verification.Cancellation
  alias ExMaude.Verification.SearchRun

  @moduletag :integration
  @model """
  mod CANCEL-SEARCH is
    protecting NAT .
    rl [next] : N:Nat => s(N:Nat) .
  endm
  """
  @query %{
    module: "CANCEL-SEARCH",
    initial: "0",
    pattern: "0",
    arrow: "=>+",
    max_depth: :unbounded,
    max_solutions: 2
  }

  setup_all do
    assert path = ExMaude.Binary.find(), "Maude executable is required"
    {:ok, path: path}
  end

  test "an early request retains exact identity and no completion claim", %{path: path} do
    handle = start_supervised!({Cancellation, []})
    assert :ok = Cancellation.request(handle)
    assert :ok = Cancellation.request(handle)
    assert {:ok, receipt} = run(path, handle)
    cancelled(receipt)
    assert receipt.model_digest == sha256(@model)
    assert receipt.backend == :port
    assert receipt.limits.max_states == :unsupported
    assert receipt.query_digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert receipt.executable_digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert receipt.executable_version != ""
    assert receipt.session_id != ""
    assert {:error, %Error{type: :validation}} = Cancellation.request(handle)
    assert {:error, %Error{type: :validation}} = run(path, handle)
  end

  test "cancelling an actual unbounded Maude computation retires its worker", %{path: path} do
    handle = start_supervised!({Cancellation, []})
    task = Task.async(fn -> run(path, handle) end)
    worker = await_worker(handle)
    assert Process.alive?(worker)
    state = :sys.get_state(worker)
    assert state.pending != nil
    os_pid = Integer.to_string(state.os_pid)
    assert {_, 0} = System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true)
    assert :ok = Cancellation.request(handle)
    assert {:ok, receipt} = Task.await(task, 10_000)
    cancelled(receipt)
    refute Process.alive?(worker)
    assert eventually(fn -> dead_os?(os_pid) end)
  end

  test "one instance cannot cancel another or admit a second run", %{path: path} do
    first = start_supervised!(Supervisor.child_spec({Cancellation, []}, id: :first))
    second = start_supervised!(Supervisor.child_spec({Cancellation, []}, id: :second))
    a = Task.async(fn -> run(path, first) end)
    b = Task.async(fn -> run(path, second) end)
    first_worker = await_worker(first)
    second_worker = await_worker(second)
    assert {:error, %Error{type: :validation}} = run(path, first)
    assert :ok = Cancellation.request(first)
    assert {:ok, receipt_a} = Task.await(a, 10_000)
    cancelled(receipt_a)
    refute Process.alive?(first_worker)
    assert Process.alive?(second_worker)
    assert :ok = Cancellation.request(second)
    assert {:ok, receipt_b} = Task.await(b, 10_000)
    cancelled(receipt_b)
    refute receipt_a.session_id == receipt_b.session_id
  end

  test "owner loss retires the registered native worker", %{path: path} do
    handle = start_supervised!({Cancellation, []})
    {owner, ref} = spawn_monitor(fn -> run(path, handle) end)
    worker = await_worker(handle)
    os_pid = :sys.get_state(worker).os_pid |> Integer.to_string()
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert eventually(fn -> not Process.alive?(worker) and dead_os?(os_pid) end)

    assert eventually(fn ->
             match?({:error, %Error{type: :validation}}, Cancellation.request(handle))
           end)
  end

  test "supervisor shutdown cannot produce completed evidence", %{path: path} do
    handle = start_supervised!({Cancellation, []})
    task = Task.async(fn -> run(path, handle) end)
    worker = await_worker(handle)
    os_pid = :sys.get_state(worker).os_pid |> Integer.to_string()
    assert :ok = stop_supervised(Cancellation)
    assert {:ok, receipt} = Task.await(task, 10_000)
    assert receipt.termination == :worker_loss
    assert receipt.solutions == []
    assert receipt.trace == nil
    assert eventually(fn -> not Process.alive?(worker) and dead_os?(os_pid) end)
  end

  test "completed runs reject late requests without changing receipts", %{path: path} do
    handle = start_supervised!({Cancellation, []})
    query = %{@query | initial: "0", pattern: "0", max_depth: 1, arrow: "=>*", max_solutions: 1}
    assert {:ok, receipt} = SearchRun.run(@model, query, maude_path: path, cancellation: handle)
    assert receipt.termination == :solution_limit
    assert [%{state_num: 0}] = receipt.solutions
    assert {:error, %Error{type: :validation}} = Cancellation.request(handle)
    assert receipt.termination == :solution_limit
  end

  @tag timeout: 600_000
  property "generated early and late request schedules retain their independent outcomes", %{
    path: path
  } do
    check all(
            phase <- member_of([:early, :late]),
            requests <- integer(1..6),
            initial <- integer(0..20),
            max_runs: 300
          ) do
      {:ok, handle} = Cancellation.start_link([])

      try do
        query = %{
          @query
          | initial: Integer.to_string(initial),
            pattern: Integer.to_string(initial)
        }

        if phase == :early do
          for _ <- 1..requests, do: assert(:ok == Cancellation.request(handle))

          assert {:ok, receipt} =
                   SearchRun.run(@model, query, maude_path: path, cancellation: handle)

          cancelled(receipt)
        else
          query = %{query | max_depth: 1, arrow: "=>*", max_solutions: 1}

          assert {:ok, receipt} =
                   SearchRun.run(@model, query, maude_path: path, cancellation: handle)

          assert receipt.termination == :solution_limit
          assert [%{state_num: 0}] = receipt.solutions
        end

        for _ <- 1..requests do
          assert {:error, %Error{type: :validation}} = Cancellation.request(handle)
        end
      after
        GenServer.stop(handle)
      end
    end
  end

  defp run(path, handle),
    do: SearchRun.run(@model, @query, maude_path: path, timeout: 10_000, cancellation: handle)

  defp cancelled(receipt) do
    assert receipt.termination == :cancelled
    assert %Error{type: :cancelled} = receipt.error
    assert receipt.solutions == []
    assert receipt.states_explored == nil
    assert receipt.trace == nil
    assert receipt.depth_probe == nil
    assert receipt.raw_output_digest == nil
  end

  defp await_worker(handle) do
    assert eventually(fn ->
             state = :sys.get_state(handle)

             is_pid(state.worker) and Process.alive?(state.worker) and
               :sys.get_state(state.worker).pending != nil
           end)

    :sys.get_state(handle).worker
  end

  defp dead_os?(pid) do
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    status != 0
  end

  defp eventually(condition, attempts \\ 500)
  defp eventually(condition, 0), do: condition.()

  defp eventually(condition, attempts) do
    if condition.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(condition, attempts - 1)
        )
  end

  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
