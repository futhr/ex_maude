defmodule ExMaude.IoT.ConflictParser do
  @moduledoc """
  Parses Maude conflict detection output into Elixir structures.

  This module handles extracting conflict information from Maude's output format,
  including balanced parenthesis parsing for nested conflict expressions.

  ## Overview

  After Maude processes a conflict detection command, it returns output in a
  specific format. This module parses that output into structured Elixir maps.

  ## Maude Output Format

  Maude returns conflict information in this format:

      result ConflictSet: noConflict

      result ConflictSet: conflict(stateConflict,
        rule("motion-light", ...),
        rule("night-mode", ...),
        "Both rules modify the same property with different values")

  Multiple conflicts are separated by `|`:

      conflict(...) | conflict(...) | conflict(...)

  ## Conflict Types

  The parser recognizes four conflict types from the AutoIoT paper:

  | Maude Type | Elixir Atom | Description |
  |------------|-------------|-------------|
  | `stateConflict` | `:state_conflict` | Same device, incompatible states |
  | `envConflict` | `:env_conflict` | Opposing environmental effects |
  | `stateCascade` | `:state_cascade` | Rule output triggers conflicting rule |
  | `stateEnvCascade` | `:state_env_cascade` | Combined cascading effects |

  ## Parsed Output

  Each conflict is parsed into a map:

      %{
        type: :state_conflict,
        rule1: "motion-light",
        rule2: "night-mode",
        reason: "Both rules modify the same property with different values"
      }

  ## Parsing Algorithm

  The parser uses balanced parenthesis tracking to handle nested expressions:

  1. Locate `conflict(` markers in the output
  2. Track parenthesis depth to find matching close paren
  3. Extract conflict type, rule IDs, and reason from each conflict
  4. Deduplicate results (Maude may report same conflict multiple ways)

  ## Edge Cases

  - Returns empty list `[]` for `noConflict` output
  - Returns empty list for output without `conflict(` markers
  - Skips malformed conflict expressions that can't be parsed
  - Handles whitespace and newlines in Maude output

  ## Usage

  This module is used internally by `ExMaude.IoT.detect_conflicts/2`:

      # Internal usage
      conflicts = ExMaude.IoT.ConflictParser.parse_conflicts(maude_output)
      # => [%{type: :state_conflict, rule1: "r1", rule2: "r2", reason: "..."}]

  ## See Also

  - `ExMaude.IoT` - High-level conflict detection API
  - `ExMaude.IoT.Encoder` - Encoding rules to Maude syntax
  - [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - Conflict type definitions
  """

  @type conflict_type :: :state_conflict | :env_conflict | :state_cascade | :state_env_cascade

  @type conflict :: %{
          type: conflict_type(),
          rule1: String.t(),
          rule2: String.t(),
          reason: String.t()
        }

  @doc """
  Parses Maude output to extract conflict information.

  Returns an empty list if no conflicts are found, or a list of conflict maps.

  ## Examples

      output = "result ConflictSet: noConflict"
      [] = parse_conflicts(output)

      output = "result ConflictSet: conflict(stateConflict, rule(\\"r1\\"...), rule(\\"r2\\"...), \\"reason\\")"
      [%{type: :state_conflict, rule1: "r1", rule2: "r2", reason: "reason"}] = parse_conflicts(output)
  """
  @spec parse_conflicts(String.t()) :: [conflict()]
  def parse_conflicts(output) do
    cond do
      String.contains?(output, "noConflict") and not String.contains?(output, "conflict(") ->
        []

      String.contains?(output, "conflict(") ->
        parse_conflict_list(output)

      true ->
        []
    end
  end

  # Private functions

  defp parse_conflict_list(output) do
    # Normalize output - remove newlines and extra whitespace
    normalized = output |> String.replace(~r/\r?\n/, " ") |> String.replace(~r/\s+/, " ")

    # Extract individual conflicts from the output
    # Conflicts can be joined with | or appear individually
    extract_conflicts(normalized)
    |> Enum.map(&parse_single_conflict/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_conflicts(output) do
    # Find conflict expressions by tracking balanced parentheses
    find_balanced_conflicts(output, [])
  end

  defp find_balanced_conflicts(str, acc) do
    case :binary.match(str, "conflict(") do
      :nomatch ->
        Enum.reverse(acc)

      {start_pos, _} ->
        # Extract from "conflict(" to matching ")"
        rest = binary_part(str, start_pos, byte_size(str) - start_pos)

        case extract_balanced_parens(rest, 0, 0) do
          {:ok, conflict_str, remaining} ->
            find_balanced_conflicts(remaining, [conflict_str | acc])

          :error ->
            # Skip this match and continue
            skip_len = byte_size(str) - start_pos - 9

            if skip_len > 0 do
              remaining = binary_part(str, start_pos + 9, skip_len)
              find_balanced_conflicts(remaining, acc)
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
        # Found the matching close paren
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

  defp extract_balanced_parens(_str, _depth, _pos), do: :error

  defp parse_single_conflict(conflict_str) do
    # Extract conflict type (first identifier after "conflict(")
    type_match = Regex.run(~r/conflict\((\w+),/, conflict_str)

    # Extract rule IDs - they're the first quoted string after "rule("
    # Note: Maude output may have whitespace between "rule(" and the quote
    rule_ids =
      Regex.scan(~r/rule\(\s*"([^"]+)"/, conflict_str)
      |> Enum.map(fn [_, id] -> id end)

    # Extract the reason - it's the last quoted string before the final ")"
    # We find all quoted strings and take the last one that looks like a reason
    all_quoted =
      Regex.scan(~r/"([^"]+)"/, conflict_str)
      |> Enum.map(fn [_, str] -> str end)

    # The reason is a complete sentence/phrase, usually at the end
    # Filter to find strings that look like reasons (contain spaces, end without special chars)
    reason =
      all_quoted
      |> Enum.reverse()
      |> Enum.find(fn s ->
        String.contains?(s, " ") or
          String.ends_with?(s, "changes") or
          String.ends_with?(s, "detected") or
          String.ends_with?(s, "rule")
      end)

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

  defp parse_conflict_type("stateConflict"), do: :state_conflict
  defp parse_conflict_type("envConflict"), do: :env_conflict
  defp parse_conflict_type("stateCascade"), do: :state_cascade
  defp parse_conflict_type("stateEnvCascade"), do: :state_env_cascade
  defp parse_conflict_type(_other), do: :unknown_conflict
end
