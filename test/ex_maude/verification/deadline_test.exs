defmodule ExMaude.Verification.DeadlineTest do
  use ExUnit.Case, async: false
  alias ExMaude.Verification.Cancellation
  alias ExMaude.Verification.SearchRun
  @moduletag :integration
  @model "mod DEADLINE is protecting NAT . rl [next] : N:Nat => s(N:Nat) . endm\n"
  @query %{
    module: "DEADLINE",
    initial: "0",
    pattern: "0",
    max_depth: :unbounded,
    max_solutions: 2
  }

  test "expired setup never starts executable identification" do
    {path, phase_file, _} = fake("0", "0", "0")

    assert {:error, %ExMaude.Error{type: :timeout}} =
             SearchRun.run(@model, @query,
               maude_path: path,
               deadline_ms: System.monotonic_time(:millisecond) - 1
             )

    refute File.exists?(phase_file)
  end

  test "invalid deadline refuses as validation" do
    path = ExMaude.Binary.find() || flunk("Maude executable required")

    for value <- [nil, "1", 1.0, :none] do
      assert {:error, %ExMaude.Error{type: :validation}} =
               SearchRun.run(@model, @query, maude_path: path, deadline_ms: value)
    end
  end

  test "finite actual completion retains declared deadline and omitted shape" do
    path = ExMaude.Binary.find() || flunk("Maude executable required")
    query = %{@query | max_depth: 1, max_solutions: 1}
    deadline = System.monotonic_time(:millisecond) + 2000
    assert {:ok, bounded} = SearchRun.run(@model, query, maude_path: path, deadline_ms: deadline)
    assert bounded.termination == :solution_limit
    assert bounded.limits.deadline_ms == deadline
    assert [%{state_num: 0}] = bounded.solutions
    assert {:ok, legacy} = SearchRun.run(@model, query, maude_path: path)
    refute Map.has_key?(legacy.limits, :deadline_ms)
    assert bounded.query_digest == legacy.query_digest
  end

  test "actual unbounded timeout clears findings and retires its native process" do
    maude = ExMaude.Binary.find() || flunk("Maude executable required")
    stem = temporary()
    path = stem <> ".sh"
    pid_file = stem <> ".pid"
    File.write!(path, "#!/bin/sh\nprintf '%s' \"$$\" > '#{pid_file}'\nexec '#{maude}' \"$@\"\n")
    File.chmod!(path, 0o700)

    on_exit(fn ->
      File.rm(path)
      File.rm(pid_file)
    end)

    deadline = System.monotonic_time(:millisecond) + 1000
    result = SearchRun.run(@model, @query, maude_path: path, timeout: 5000, deadline_ms: deadline)
    retain("actual-timeout-result", result)
    assert {:ok, receipt} = result

    retain("actual-timeout", receipt)
    assert_timeout(receipt, deadline)
    os_pid = File.read!(pid_file) |> String.trim()

    assert eventually(fn ->
             elem(System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true), 1) != 0
           end)
  end

  test "path retrieval shares the search budget and clears partial findings" do
    {path, phase_file, pid_file} = fake("0.1", "1", "0")
    deadline = System.monotonic_time(:millisecond) + 500

    assert {:ok, receipt} =
             SearchRun.run(@model, finite_query(),
               maude_path: path,
               timeout: 2000,
               deadline_ms: deadline
             )

    retain("path-timeout", %{receipt: receipt, phases: File.read!(phase_file)})
    assert_timeout(receipt, deadline)
    assert File.read!(phase_file) =~ "path"
    refute File.read!(phase_file) =~ "path-finished"
    assert retired?(pid_file)
  end

  test "frontier probe shares the same deadline and cannot retain a completed witness" do
    {path, phase_file, pid_file} = fake("0", "0", "3")
    deadline = System.monotonic_time(:millisecond) + 1500

    result =
      SearchRun.run(@model, finite_query(),
        maude_path: path,
        timeout: 5000,
        deadline_ms: deadline
      )

    retain("probe-timeout-result", %{result: result, phases: File.read!(phase_file)})
    assert {:ok, receipt} = result
    retain("probe-timeout", %{receipt: receipt, phases: File.read!(phase_file)})
    assert_timeout(receipt, deadline)
    assert File.read!(phase_file) =~ "probe"
    assert retired?(pid_file)
  end

  test "startup and preloading consume one absolute budget" do
    {path, phase_file, pid_file} = fake("0", "0", "0", "0.2")
    deadline = System.monotonic_time(:millisecond) + 300

    assert {:ok, receipt} =
             SearchRun.run(@model, finite_query(),
               maude_path: path,
               timeout: 2000,
               deadline_ms: deadline
             )

    retain("startup-timeout", %{receipt: receipt, phases: File.read!(phase_file)})
    assert_timeout(receipt, deadline)
    refute File.read!(phase_file) =~ "search"
    assert retired?(pid_file)
  end

  test "accepted cancellation preserves its disposition under a future deadline" do
    maude = ExMaude.Binary.find() || flunk("Maude executable required")
    {:ok, cancellation} = Cancellation.start_link([])
    on_exit(fn -> if Process.alive?(cancellation), do: GenServer.stop(cancellation) end)
    assert :ok = Cancellation.request(cancellation)

    assert {:ok, receipt} =
             SearchRun.run(@model, @query,
               maude_path: maude,
               cancellation: cancellation,
               deadline_ms: System.monotonic_time(:millisecond) + 2000
             )

    assert receipt.termination == :cancelled
    assert receipt.solutions == []
    assert receipt.trace == nil
  end

  defp finite_query, do: %{@query | max_depth: 2}

  test "recorded cancellation wins closure even when startup consumes the deadline" do
    {path, phase_file, pid_file} = fake("0", "0", "0", "0.2")
    {:ok, cancellation} = Cancellation.start_link([])
    on_exit(fn -> if Process.alive?(cancellation), do: GenServer.stop(cancellation) end)
    assert :ok = Cancellation.request(cancellation)
    deadline = System.monotonic_time(:millisecond) + 300

    assert {:ok, receipt} =
             SearchRun.run(@model, finite_query(),
               maude_path: path,
               cancellation: cancellation,
               timeout: 2000,
               deadline_ms: deadline
             )

    retain("cancelled-expiry", %{receipt: receipt, phases: File.read!(phase_file)})
    assert System.monotonic_time(:millisecond) >= deadline
    assert receipt.termination == :cancelled
    assert receipt.solutions == []
    assert receipt.trace == nil
    assert {:error, %ExMaude.Error{type: :validation}} = Cancellation.request(cancellation)
    assert retired?(pid_file)
  end

  test "the controlled CLI completion fixture works before applying a deadline" do
    {path, phase_file, pid_file} = fake("0", "0", "0")
    assert {:ok, receipt} = SearchRun.run(@model, finite_query(), maude_path: path)
    assert receipt.termination == :completed_declared_bound
    assert [%{state_num: 1}] = receipt.solutions
    assert receipt.trace.state_num == 1
    assert File.read!(phase_file) =~ "probe"
    assert retired?(pid_file)
  end

  defp assert_timeout(receipt, deadline) do
    assert receipt.termination == :timeout
    assert %ExMaude.Error{type: :timeout} = receipt.error
    assert receipt.limits.deadline_ms == deadline
    assert receipt.solutions == []
    assert receipt.states_explored == nil
    assert receipt.trace == nil
    assert receipt.depth_probe == nil
    assert receipt.raw_output_digest == nil
  end

  defp fake(search_delay, path_delay, probe_delay, startup_delay \\ "0") do
    stem = temporary()
    path = stem <> ".sh"
    phase_file = stem <> ".phases"
    pid_file = stem <> ".pid"

    File.write!(path, """
    #!/bin/sh
    printf '%s' "$$" > '#{pid_file}'
    if [ "$1" = "--version" ]; then printf 'version\\n' >> '#{phase_file}'; printf 'fixture 1\\n'; exit 0; fi
    printf 'startup\\n' >> '#{phase_file}'
    sleep #{startup_delay}
    printf 'Maude> '
    while IFS= read -r line; do
      case "$line" in
        load*) printf 'load\\n' >> '#{phase_file}'; sleep #{startup_delay}; printf 'Maude> ' ;;
        'search [2, 3]'*) printf 'probe\\n' >> '#{phase_file}'; sleep #{probe_delay}; printf '%s\\n\\nSolution 1 (state 1)\\nempty substitution\\n\\nNo more solutions.\\nstates: 2\\nMaude> ' "$line" ;;
        search*) printf 'search\\n' >> '#{phase_file}'; sleep #{search_delay}; printf '%s\\n\\nSolution 1 (state 1)\\nempty substitution\\n\\nNo more solutions.\\nstates: 2\\nMaude> ' "$line" ;;
        'show path'*) printf 'path\\n' >> '#{phase_file}'; sleep #{path_delay}; printf 'path-finished\\n' >> '#{phase_file}'; printf 'state 0, Nat: 0\\n===[ rl [next] : N:Nat => s(N:Nat) . ]===>\\nstate 1, Nat: 1\\nMaude> ' ;;
        *) printf 'Maude> ' ;;
      esac
    done
    """)

    File.chmod!(path, 0o700)
    on_exit(fn -> Enum.each([path, phase_file, pid_file], &File.rm/1) end)
    {path, phase_file, pid_file}
  end

  defp retired?(pid_file) do
    os_pid = File.read!(pid_file) |> String.trim()
    eventually(fn -> elem(System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true), 1) != 0 end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp temporary,
    do:
      Path.join(
        System.tmp_dir!(),
        "exmaude-deadline-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

  defp retain(name, value) do
    if directory = System.get_env("BUDGET_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, name <> ".etf"), :erlang.term_to_binary(value))
    end
  end
end
