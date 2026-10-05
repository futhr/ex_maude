defmodule ExMaude.Verification.PathIntegrationTest do
  use ExUnit.Case, async: false

  alias ExMaude.Verification.Path
  alias ExMaude.Verification.SearchRun

  @moduletag :integration
  @model """
  mod PATH-REPLAY is
    sort S .
    ops a b c : -> S [ctor] .
    rl [one] : a => b .
    rl [two] : b => c .
  endm
  """

  setup_all do
    assert path = ExMaude.Binary.find(), "selected Maude executable is required"
    %{maude: path}
  end

  test "all states and transitions decode from the actual retired session", fixture do
    query = %{module: "PATH-REPLAY", initial: "a", pattern: "c", max_depth: 5, max_solutions: 5}
    assert {:ok, receipt} = SearchRun.run(@model, query, maude_path: fixture.maude)
    assert receipt.termination == :completed_declared_bound
    assert {:ok, path} = Path.decode(receipt.trace.bytes, receipt.trace.state_num)
    assert path.digest == receipt.trace.digest

    assert path.nodes == [
             %{state_num: 0, sort: "S", value: "a"},
             %{state_num: 1, sort: "S", value: "b"},
             %{state_num: 2, sort: "S", value: "c"}
           ]

    assert path.edges == [
             %{from_state: 0, to_state: 1, rule: "rl [one] : a => b .", label: "one"},
             %{from_state: 1, to_state: 2, rule: "rl [two] : b => c .", label: "two"}
           ]

    assert receipt.model_digest == digest(@model)
    assert receipt.trace.state_num == 2
  end

  test "a real state-zero path remains one node without fabricated steps", fixture do
    query = %{module: "PATH-REPLAY", initial: "b", pattern: "b", max_depth: 5, max_solutions: 1}
    assert {:ok, receipt} = SearchRun.run(@model, query, maude_path: fixture.maude)
    assert receipt.termination == :solution_limit
    assert {:ok, path} = Path.decode(receipt.trace.bytes, 0)
    assert path.nodes == [%{state_num: 0, sort: "S", value: "b"}]
    assert path.edges == []
    assert path.digest == receipt.trace.digest
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
