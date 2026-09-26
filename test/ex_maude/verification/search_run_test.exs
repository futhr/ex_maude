defmodule ExMaude.Verification.SearchRunTest do
  use ExUnit.Case, async: false

  alias ExMaude.Verification.SearchRun

  @moduletag :integration

  @model """
  mod CONJUNCT-SEARCH is
    sort State .
    ops a b c : -> State [ctor] .
    rl [to-b] : a => b .
    rl [to-c] : a => c .
  endm
  """

  setup_all do
    assert path = ExMaude.Binary.find(), "selected Maude executable is required"
    {:ok, path: path}
  end

  test "distinguishes bounded completion, cutoff and a finite no-solution observation", %{
    path: path
  } do
    query = %{module: "CONJUNCT-SEARCH", initial: "a", pattern: "S:State", max_depth: 5}

    assert {:ok, cutoff} =
             SearchRun.run(@model, Map.put(query, :max_solutions, 1), maude_path: path)

    assert cutoff.termination == :solution_limit
    assert length(cutoff.solutions) == 1
    assert cutoff.trace.state_num == 0
    assert cutoff.trace.digest == digest(cutoff.trace.bytes)

    assert {:ok, complete} =
             SearchRun.run(@model, Map.put(query, :max_solutions, 5), maude_path: path)

    assert complete.termination == :completed_declared_bound
    assert length(complete.solutions) == 3
    assert complete.states_explored == 3
    assert complete.model_digest == cutoff.model_digest
    refute complete.query_digest == cutoff.query_digest
    refute complete.session_id == cutoff.session_id
    assert complete.raw_output_digest =~ ~r/^sha256:[0-9a-f]{64}$/

    assert {:ok, absent} =
             SearchRun.run(
               @model,
               query
               |> Map.put(:initial, "b")
               |> Map.put(:pattern, "c")
               |> Map.put(:max_solutions, 5),
               maude_path: path
             )

    assert absent.termination == :completed_declared_bound
    assert absent.solutions == []
    assert absent.trace == nil
  end

  test "retrieves a nontrivial path inside the same isolated session", %{path: path} do
    query = %{
      module: "CONJUNCT-SEARCH",
      initial: "a",
      pattern: "c",
      max_depth: 5,
      max_solutions: 5
    }

    assert {:ok, result} = SearchRun.run(@model, query, maude_path: path)
    assert result.termination == :completed_declared_bound
    assert [%{state_num: 2}] = result.solutions
    assert result.trace.state_num == 2
    assert result.trace.bytes =~ "state 0, State: a"
    assert result.trace.bytes =~ "state 2, State: c"
    assert result.trace.digest == digest(result.trace.bytes)
  end

  test "concurrent searches keep independent sessions and paths", %{path: path} do
    query = %{
      module: "CONJUNCT-SEARCH",
      initial: "a",
      pattern: "c",
      max_depth: 5,
      max_solutions: 5
    }

    receipts =
      1..6
      |> Task.async_stream(
        fn _ -> SearchRun.run(@model, query, maude_path: path) end,
        max_concurrency: 6,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert length(Enum.uniq_by(receipts, & &1.session_id)) == 6
    assert length(Enum.uniq_by(receipts, & &1.query_digest)) == 1
    assert Enum.all?(receipts, &(&1.termination == :completed_declared_bound))
    assert Enum.all?(receipts, &(&1.trace.state_num == 2))
  end

  test "response overflow remains inconclusive", %{path: path} do
    query = %{
      module: "CONJUNCT-SEARCH",
      initial: "a",
      pattern: "S:State",
      max_depth: 5,
      max_solutions: 5
    }

    assert {:ok, result} =
             SearchRun.run(@model, query, maude_path: path, max_response_bytes: 256)

    assert result.termination == :output_truncation
    assert result.solutions == []
    assert result.raw_output_digest == nil
  end

  test "refuses invalid bounds before starting a worker", %{path: path} do
    assert {:error, %ExMaude.Error{type: :validation}} =
             SearchRun.run(
               @model,
               %{module: "CONJUNCT-SEARCH", initial: "a", pattern: "c", max_depth: 0},
               maude_path: path
             )

    assert {:error, %ExMaude.Error{type: :validation}} =
             SearchRun.run(
               @model,
               %{module: "CONJUNCT-SEARCH", initial: "a . show path 0", pattern: "c"},
               maude_path: path
             )
  end

  defp digest(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
