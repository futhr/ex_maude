defmodule ExMaude.Verification.PathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExMaude.Error
  alias ExMaude.Verification.Path

  @bytes "state 0, S: a\n===[ rl [one] : a => b . ]===>\nstate 2, S: b\n===[ rl [two] : b => c . ]===>\nstate 4, S: c"
  @nodes [
    %{state_num: 0, sort: "S", value: "a"},
    %{state_num: 2, sort: "S", value: "b"},
    %{state_num: 4, sort: "S", value: "c"}
  ]
  @edges [
    %{from_state: 0, to_state: 2, rule: "rl [one] : a => b .", label: "one"},
    %{from_state: 2, to_state: 4, rule: "rl [two] : b => c .", label: "two"}
  ]

  test "retains every node and edge with nonconsecutive graph IDs" do
    assert {:ok, path} = Path.decode(@bytes, 4)
    assert path.parser_version == "ex_maude.path.v1"
    assert path.state_num == 4
    assert path.digest == digest(@bytes)
    assert path.nodes == @nodes
    assert path.edges == @edges
  end

  test "a zero-edge path is explicit" do
    assert {:ok, path} = Path.decode("state 0, S: a", 0)
    assert path.nodes == [%{state_num: 0, sort: "S", value: "a"}]
    assert path.edges == []
  end

  test "line separator variants retain exact original identity" do
    for bytes <- [@bytes <> "\n", String.replace(@bytes, "\n", "\r\n") <> "\r\n"] do
      assert {:ok, path} = Path.decode(bytes, 4)
      assert path.nodes == @nodes
      assert path.edges == @edges
      assert path.digest == digest(bytes)
      refute path.digest == digest(@bytes)
    end
  end

  test "unlabeled and multiline rules retain their full text" do
    bytes = "state 0, S: a\n===[ crl a =>\nb if true . ]===>\nstate 1, S: b"
    assert {:ok, path} = Path.decode(bytes, 1)

    assert path.edges == [
             %{from_state: 0, to_state: 1, rule: "crl a =>\nb if true .", label: nil}
           ]
  end

  test "malformed or mismatched paths cannot become empty success" do
    invalid = [
      "",
      "Warning: no path",
      "prefix\n" <> @bytes,
      @bytes <> "\nextra",
      String.replace(@bytes, "state 4", "state 2"),
      String.replace(@bytes, "state 0", "state 1"),
      String.replace(@bytes, "===[ rl [one] : a => b . ]===>\n", ""),
      @bytes <> "\n===[ rl c => a . ]===>",
      String.replace(@bytes, "state 2", "state 02"),
      String.replace(@bytes, "state 2", "state 4294967296"),
      "state 0, S: a\rbroken",
      <<255>>,
      "state 0, S: a" <> <<0>>,
      "state 0, S: a\n\n"
    ]

    for bytes <- invalid, do: assert({:error, %Error{type: :parse_error}} = Path.decode(bytes, 4))
    assert {:error, %Error{type: :parse_error}} = Path.decode(@bytes, 3)
    assert {:error, %Error{type: :parse_error}} = Path.decode("state 0, S: a\n\n", 0)
    repeated = "state 0, S: a\n===[ rl a => b . ]===> ]===>\nstate 1, S: b"
    assert {:error, %Error{type: :parse_error}} = Path.decode(repeated, 1)
  end

  test "explicit parser resources cannot be silently exceeded" do
    assert {:error, %Error{type: :response_too_large}} = Path.decode(@bytes, 4, max_nodes: 2)

    assert {:error, %Error{type: :response_too_large}} =
             Path.decode(@bytes, 4, max_bytes: byte_size(@bytes) - 1)

    assert {:ok, _} = Path.decode(@bytes, 4, max_nodes: 3, max_bytes: byte_size(@bytes))
  end

  test "malformed configuration refuses before parsing" do
    for opts <- [
          [max_nodes: 0],
          [max_bytes: 0],
          [unknown: 1],
          [max_nodes: 2, max_nodes: 3],
          [max_nodes: 10_001],
          :invalid
        ] do
      assert {:error, %Error{type: :validation}} = Path.decode(@bytes, 4, opts)
    end

    for state <- [-1, 4_294_967_296, "4"],
        do: assert({:error, %Error{type: :validation}} = Path.decode(@bytes, state))
  end

  property "independent printed chains retain every graph node and rule" do
    check all(
            gaps <- list_of(integer(1..5), min_length: 1, max_length: 20),
            value <- integer(0..100),
            max_runs: 300
          ) do
      numbers = [0 | Enum.scan(gaps, 0, &+/2)]

      nodes =
        Enum.map(numbers, &%{state_num: &1, sort: "Nat", value: Integer.to_string(value + &1)})

      edges =
        nodes
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] ->
          %{
            from_state: a.state_num,
            to_state: b.state_num,
            rule: "rl [edge-#{a.state_num}] : #{a.value} => #{b.value} .",
            label: "edge-#{a.state_num}"
          }
        end)

      bytes = render(nodes, edges)
      original = retain_original(bytes, List.last(numbers), nodes, edges)
      result = Path.decode(bytes, List.last(numbers))
      retain_result(original, result)
      assert {:ok, path} = result
      assert path.nodes == nodes
      assert path.edges == edges
      assert path.digest == digest(bytes)
      assert {:error, %Error{type: :parse_error}} = Path.decode(bytes, List.last(numbers) + 1)
    end
  end

  defp render([first | rest], edges) do
    initial = "state #{first.state_num}, #{first.sort}: #{first.value}"

    Enum.zip(rest, edges)
    |> Enum.reduce(initial, fn {node, edge}, bytes ->
      bytes <> "\n===[ #{edge.rule} ]===>\nstate #{node.state_num}, #{node.sort}: #{node.value}"
    end)
  end

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp retain_original(bytes, target, nodes, edges) do
    case System.get_env("PATH_EVIDENCE_DIR") do
      nil ->
        nil

      directory ->
        File.mkdir_p!(directory)
        path = Elixir.Path.join(directory, "path-#{System.unique_integer([:positive])}")

        File.write!(
          path <> ".etf",
          :erlang.term_to_binary(%{bytes: bytes, target: target, nodes: nodes, edges: edges})
        )

        path
    end
  end

  defp retain_result(nil, _), do: :ok

  defp retain_result(path, result),
    do: File.write!(path <> "-actual.etf", :erlang.term_to_binary(result))
end
