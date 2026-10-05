defmodule ExMaude.Verification.CommandEchoIntegrationTest do
  use ExUnit.Case, async: false
  alias ExMaude.Verification.SearchRun
  @moduletag :integration
  @model """
  mod ECHO is
    protecting NAT .
    sort S .
    op pair : Nat Nat -> S [ctor] .
    op bad : -> S [ctor] .
    rl [fail] : pair(2, 3) => bad .
  endm
  """
  test "actual compact and spaced queries retain distinct bytes and identical paths" do
    path = ExMaude.Binary.find() || flunk("Maude executable required")

    query = %{
      module: "ECHO",
      initial: "pair(2,3)",
      pattern: "bad",
      max_depth: 2,
      max_solutions: 2
    }

    assert {:ok, compact} = SearchRun.run(@model, query, maude_path: path)

    assert {:ok, spaced} =
             SearchRun.run(@model, %{query | initial: "pair(2, 3)"}, maude_path: path)

    if directory = System.get_env("ECHO_EVIDENCE_DIR") do
      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "real-receipts.etf"),
        :erlang.term_to_binary({compact, spaced})
      )
    end

    assert compact.termination == :completed_declared_bound
    assert spaced.termination == :completed_declared_bound
    assert compact.solutions == spaced.solutions
    refute compact.query_digest == spaced.query_digest
    assert compact.model_digest == spaced.model_digest
    assert compact.trace.bytes == spaced.trace.bytes
    assert {:ok, decoded} = ExMaude.Verification.Path.decode(compact.trace.bytes, 1)
    assert length(decoded.nodes) == 2
    assert length(decoded.edges) == 1
    assert compact.parser_version == "ex_maude.search-run.v3"
  end
end
