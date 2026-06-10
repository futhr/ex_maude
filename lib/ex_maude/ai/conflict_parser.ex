defmodule ExMaude.AI.ConflictParser do
  @moduledoc """
  Parses Maude conflict-detection output from `ai-rules.maude` into
  Elixir structures.

  Companion to `ExMaude.IoT.ConflictParser`. Handles the additional
  conflict types and the `aiConflictSingle` constructor (single-rule
  conflicts like sovereignty violations and approval-gate bypasses).

  ## Maude output format

  Maude returns AI conflicts in two shapes:

      result AIConflictSet: noAIConflict

      result AIConflictSet: aiConflict(toolCallConflict,
        aiRule("rule-1", ...),
        aiRule("rule-2", ...),
        "Same agent, same tool, conflicting required arguments")

      result AIConflictSet: aiConflictSingle(sovereigntyViolation,
        aiRule("rule-3", ...),
        "Tool invocation routes through forbidden jurisdiction")

  Multiple conflicts are joined with the `||c||` operator:

      aiConflict(...) ||c|| aiConflictSingle(...) ||c|| aiConflict(...)

  ## Conflict type mapping

  | Maude constructor | Elixir atom |
  |---|---|
  | `toolCallConflict` | `:tool_call_conflict` |
  | `capabilityShadowing` | `:capability_shadowing` |
  | `packToolCompositionMismatch` | `:pack_tool_composition_mismatch` |
  | `budgetCascade` | `:budget_cascade` |
  | `costCeilingInfeasibility` | `:cost_ceiling_infeasibility` |
  | `sovereigntyViolation` | `:sovereignty_violation` |
  | `authorityEscalation` | `:authority_escalation` |
  | `approvalGateBypass` | `:approval_gate_bypass` |
  | `agentLoopCascade` | `:agent_loop_cascade` |
  | `providerRoutingInfeasibility` | `:provider_routing_infeasibility` |
  """

  @type conflict_type ::
          :tool_call_conflict
          | :capability_shadowing
          | :pack_tool_composition_mismatch
          | :budget_cascade
          | :cost_ceiling_infeasibility
          | :sovereignty_violation
          | :authority_escalation
          | :approval_gate_bypass
          | :agent_loop_cascade
          | :provider_routing_infeasibility
          | :unknown_conflict

  @type conflict :: %{
          required(:type) => conflict_type(),
          required(:reason) => String.t(),
          required(:rule1) => String.t(),
          optional(:rule2) => String.t() | nil
        }

  @doc """
  Parses Maude output to extract AI conflict information.

  Returns an empty list if no conflicts are found, or a list of
  conflict maps. Pairwise conflicts include both `:rule1` and
  `:rule2`; single-rule conflicts include only `:rule1` and a `nil`
  `:rule2`.

  ## Examples

      iex> ExMaude.AI.ConflictParser.parse_conflicts("result AIConflictSet: noAIConflict")
      []

      iex> output =
      ...>   ~s|aiConflictSingle(sovereigntyViolation, aiRule("r3", | <>
      ...>     ~s|agent(tenant("acme"), "ag-1"), alwaysP, nilInvocation, noCap, 0, 1), | <>
      ...>     ~s|"Tool invocation routes through forbidden jurisdiction")|
      ...>
      ...> ExMaude.AI.ConflictParser.parse_conflicts(output)
      [
        %{
          type: :sovereignty_violation,
          rule1: "r3",
          rule2: nil,
          reason: "Tool invocation routes through forbidden jurisdiction"
        }
      ]
  """
  @spec parse_conflicts(String.t()) :: [conflict()]
  def parse_conflicts(output) do
    cond do
      String.contains?(output, "noAIConflict") and
        not String.contains?(output, "aiConflict(") and
          not String.contains?(output, "aiConflictSingle(") ->
        []

      String.contains?(output, "aiConflict(") or
          String.contains?(output, "aiConflictSingle(") ->
        parse_conflict_list(output)

      true ->
        []
    end
  end

  defp parse_conflict_list(output) do
    normalized =
      output
      |> String.replace(~r/\r?\n/, " ")
      |> String.replace(~r/\s+/, " ")

    pairwise = extract_balanced("aiConflict(", normalized)
    single = extract_balanced("aiConflictSingle(", normalized)

    (Enum.map(pairwise, &parse_pairwise/1) ++ Enum.map(single, &parse_single/1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_balanced(marker, str) do
    do_extract_balanced(marker, str, [])
  end

  defp do_extract_balanced(marker, str, acc) do
    case :binary.match(str, marker) do
      :nomatch ->
        Enum.reverse(acc)

      {start_pos, marker_len} ->
        rest = binary_part(str, start_pos, byte_size(str) - start_pos)

        case extract_balanced_parens(rest, 0, 0) do
          {:ok, conflict_str, remaining} ->
            do_extract_balanced(marker, remaining, [conflict_str | acc])

          :error ->
            skip_len = byte_size(str) - start_pos - marker_len

            if skip_len > 0 do
              remaining = binary_part(str, start_pos + marker_len, skip_len)
              do_extract_balanced(marker, remaining, acc)
            else
              Enum.reverse(acc)
            end
        end
    end
  end

  defp extract_balanced_parens(str, depth, pos) when pos < byte_size(str) do
    char = binary_part(str, pos, 1)

    cond do
      char == "(" ->
        extract_balanced_parens(str, depth + 1, pos + 1)

      char == ")" and depth == 1 ->
        conflict_str = binary_part(str, 0, pos + 1)
        remaining_len = byte_size(str) - pos - 1

        remaining =
          if remaining_len > 0 do
            binary_part(str, pos + 1, remaining_len)
          else
            ""
          end

        {:ok, conflict_str, remaining}

      char == ")" ->
        extract_balanced_parens(str, depth - 1, pos + 1)

      true ->
        extract_balanced_parens(str, depth, pos + 1)
    end
  end

  defp extract_balanced_parens(_, _, _), do: :error

  defp parse_pairwise(conflict_str) do
    type_match = Regex.run(~r/aiConflict\((\w+),/, conflict_str)

    rule_ids =
      Regex.scan(~r/aiRule\(\s*"([^"]+)"/, conflict_str) |> Enum.map(fn [_, id] -> id end)

    reason = extract_reason(conflict_str)

    case {type_match, rule_ids, reason} do
      {[_, type], [rule1, rule2 | _], reason} when not is_nil(reason) ->
        %{
          type: parse_conflict_type(type),
          rule1: rule1,
          rule2: rule2,
          reason: reason
        }

      _ ->
        nil
    end
  end

  defp parse_single(conflict_str) do
    type_match = Regex.run(~r/aiConflictSingle\((\w+),/, conflict_str)

    rule_ids =
      Regex.scan(~r/aiRule\(\s*"([^"]+)"/, conflict_str) |> Enum.map(fn [_, id] -> id end)

    reason = extract_reason(conflict_str)

    case {type_match, rule_ids, reason} do
      {[_, type], [rule1 | _], reason} when not is_nil(reason) ->
        %{
          type: parse_conflict_type(type),
          rule1: rule1,
          rule2: nil,
          reason: reason
        }

      _ ->
        nil
    end
  end

  defp extract_reason(conflict_str) do
    ~r/"([^"]+)"/
    |> Regex.scan(conflict_str)
    |> Enum.map(fn [_, s] -> s end)
    |> Enum.reverse()
    |> Enum.find(fn s ->
      String.contains?(s, " ")
    end)
  end

  defp parse_conflict_type("toolCallConflict"), do: :tool_call_conflict
  defp parse_conflict_type("capabilityShadowing"), do: :capability_shadowing
  defp parse_conflict_type("packToolCompositionMismatch"), do: :pack_tool_composition_mismatch
  defp parse_conflict_type("budgetCascade"), do: :budget_cascade
  defp parse_conflict_type("costCeilingInfeasibility"), do: :cost_ceiling_infeasibility
  defp parse_conflict_type("sovereigntyViolation"), do: :sovereignty_violation
  defp parse_conflict_type("authorityEscalation"), do: :authority_escalation
  defp parse_conflict_type("approvalGateBypass"), do: :approval_gate_bypass
  defp parse_conflict_type("agentLoopCascade"), do: :agent_loop_cascade
  defp parse_conflict_type("providerRoutingInfeasibility"), do: :provider_routing_infeasibility
  defp parse_conflict_type(_), do: :unknown_conflict
end
