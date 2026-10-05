defmodule ExMaude.Verification.Path do
  @moduledoc """
  Decodes bounded, unwrapped Port `show path` output into ordered nodes and edges.

  Terms and printed rules remain opaque text. Decoding does not prove that a
  transition follows from a model or authenticate execution. Consumers bind the
  digest and target to their SearchRun receipt and independently replay rules.
  No worker, configuration, telemetry or application startup is involved.
  """

  alias ExMaude.Error

  @max_bytes 16_777_216
  @max_nodes 10_000
  @max_state 4_294_967_295
  @state ~r/^state (0|[1-9][0-9]{0,9}), ([^:\r\n]+): (.+)$/u
  @label ~r/^(?:crl|rl)\s+\[([^\]\r\n]+)\]\s*:/u

  @type path_node :: %{state_num: non_neg_integer(), sort: String.t(), value: String.t()}
  @type edge :: %{
          from_state: non_neg_integer(),
          to_state: non_neg_integer(),
          rule: String.t(),
          label: String.t() | nil
        }
  @type t :: %{
          parser_version: String.t(),
          digest: String.t(),
          state_num: non_neg_integer(),
          nodes: [path_node()],
          edges: [edge()]
        }

  @doc """
  Decodes complete path bytes for the requested graph state.

  `:max_bytes` and `:max_nodes` can narrow the defaults of 16 MiB and 10000 nodes.
  Invalid arguments return a validation error, exceeded caps return
  `:response_too_large`, and malformed/incomplete/mismatched paths return
  `:parse_error`. Graph IDs may skip numbers. Each printed rule is retained.
  Multiline state values are outside this decoder profile and refuse explicitly.
  """
  @spec decode(binary(), non_neg_integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def decode(bytes, target, opts \\ [])

  def decode(bytes, target, opts)
      when is_binary(bytes) and is_integer(target) and target in 0..@max_state do
    with {:ok, limits} <- limits(opts),
         :ok <- check_bytes(bytes, limits.max_bytes),
         {:ok, nodes, edges} <- parse(lines(bytes), limits.max_nodes),
         :ok <- check_target(nodes, edges, target) do
      {:ok,
       %{
         parser_version: "ex_maude.path.v1",
         digest: digest(bytes),
         state_num: target,
         nodes: nodes,
         edges: edges
       }}
    end
  end

  def decode(_, _, _), do: invalid()

  defp limits(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: keyword_limits(opts), else: invalid()
  end

  defp limits(_), do: invalid()

  defp keyword_limits(opts) do
    keys = Keyword.keys(opts)
    bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    nodes = Keyword.get(opts, :max_nodes, @max_nodes)

    if length(keys) == length(Enum.uniq(keys)) and
         Enum.all?(keys, &(&1 in [:max_bytes, :max_nodes])) and
         valid_limit?(bytes, @max_bytes) and valid_limit?(nodes, @max_nodes) do
      {:ok, %{max_bytes: bytes, max_nodes: nodes}}
    else
      invalid()
    end
  end

  defp valid_limit?(value, maximum), do: is_integer(value) and value in 1..maximum

  defp check_bytes(bytes, limit) when byte_size(bytes) > limit, do: capped(:max_bytes, limit)

  defp check_bytes(bytes, _) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>) and
         not String.contains?(String.replace(bytes, "\r\n", "\n"), "\r"),
       do: :ok,
       else: malformed()
  end

  defp lines(bytes) do
    split =
      bytes
      |> String.replace("\r\n", "\n")
      |> String.split("\n", trim: false)

    if List.last(split) == "", do: Enum.drop(split, -1), else: split
  end

  defp parse([first | rest], maximum) do
    with {:ok, node} <- parse_node(first) do
      consume(rest, [node], [], MapSet.new([node.state_num]), maximum)
    end
  end

  defp parse(_, _), do: malformed()

  defp consume([], nodes, edges, _, _), do: {:ok, Enum.reverse(nodes), Enum.reverse(edges)}

  defp consume(lines, [previous | _] = nodes, edges, seen, maximum) do
    with {:ok, rule, [next | rest]} <- rule(lines),
         :ok <- node_capacity(seen, maximum),
         {:ok, next_node} <- parse_node(next),
         false <- MapSet.member?(seen, next_node.state_num) do
      edge = %{
        from_state: previous.state_num,
        to_state: next_node.state_num,
        rule: rule,
        label: label(rule)
      }

      consume(
        rest,
        [next_node | nodes],
        [edge | edges],
        MapSet.put(seen, next_node.state_num),
        maximum
      )
    else
      {:error, _} = error -> error
      _ -> malformed()
    end
  end

  defp node_capacity(seen, maximum) do
    if MapSet.size(seen) < maximum, do: :ok, else: capped(:max_nodes, maximum)
  end

  defp parse_node(line) do
    case Regex.run(@state, line) do
      [_, number, sort, value] ->
        state = String.to_integer(number)

        if state <= @max_state and String.trim(sort) != "",
          do: {:ok, %{state_num: state, sort: sort, value: value}},
          else: malformed()

      _ ->
        malformed()
    end
  end

  defp rule(["===[ " <> first | rest]), do: rule_body(first, rest, [])
  defp rule(_), do: malformed()

  defp rule_body(line, rest, collected) do
    if String.ends_with?(line, " ]===>") do
      body =
        [binary_part(line, 0, byte_size(line) - byte_size(" ]===>")) | collected]
        |> Enum.reverse()
        |> Enum.join("\n")

      if Regex.match?(~r/^(?:crl|rl)\s/u, body) and String.ends_with?(body, ".") and
           String.contains?(body, " =>"), do: {:ok, body, rest}, else: malformed()
    else
      continue_rule(rest, [line | collected])
    end
  end

  defp continue_rule([line | rest], collected), do: rule_body(line, rest, collected)
  defp continue_rule([], _), do: malformed()

  defp label(rule) do
    case Regex.run(@label, rule) do
      [_, label] -> label
      _ -> nil
    end
  end

  defp check_target(nodes, edges, target) do
    if hd(nodes).state_num == 0 and List.last(nodes).state_num == target and
         length(edges) + 1 == length(nodes), do: :ok, else: malformed()
  end

  defp invalid, do: {:error, Error.new(:validation, "invalid path decoder arguments")}
  defp malformed, do: {:error, Error.new(:parse_error, "incomplete or malformed search path")}

  defp capped(limit, maximum),
    do:
      {:error,
       Error.new(:response_too_large, "path exceeds decoder limit",
         details: %{limit: limit, maximum: maximum}
       )}

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
