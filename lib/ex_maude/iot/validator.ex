defmodule ExMaude.IoT.Validator do
  @moduledoc """
  Validates IoT rule structures before conflict detection.

  This module provides validation for IoT rules, triggers, and actions
  before they are sent to Maude for conflict detection. Validation catches
  structural errors early with meaningful error messages.

  ## Overview

  Validation is performed automatically by `ExMaude.IoT.detect_conflicts/2`,
  but can also be called directly to check rules before submission:

      :ok = ExMaude.IoT.Validator.validate_rule(rule)
      {:error, errors} = ExMaude.IoT.Validator.validate_rule(%{})

  ## Required Rule Fields

  Every rule must have the following fields:

  | Field | Type | Description |
  |-------|------|-------------|
  | `:id` | `String.t()` | Unique rule identifier |
  | `:thing_id` | `String.t()` | Target device identifier |
  | `:trigger` | `trigger()` | Condition that activates the rule |
  | `:actions` | `[action()]` | List of actions to execute |
  | `:priority` | `integer()` | Optional priority (default: 1) |

  ## Trigger Validation

  Valid trigger formats:

  - `{:prop_eq, property, value}` - Property equals value
  - `{:prop_gt, property, number}` - Property greater than number
  - `{:prop_lt, property, number}` - Property less than number
  - `{:prop_gte, property, number}` - Property greater than or equal
  - `{:prop_lte, property, number}` - Property less than or equal
  - `{:env_eq, property, value}` - Environment equals value
  - `{:env_gt, property, number}` - Environment greater than number
  - `{:env_lt, property, number}` - Environment less than number
  - `{:always}` - Always triggered
  - `{:and, trigger, trigger}` - Logical AND
  - `{:or, trigger, trigger}` - Logical OR
  - `{:not, trigger}` - Logical NOT

  ## Action Validation

  Valid action formats:

  - `{:set_prop, thing_id, property, value}` - Set device property
  - `{:set_env, property, value}` - Set environment variable
  - `{:invoke, thing_id, action_name}` - Invoke device action

  ## Depth Limiting

  Nested triggers (`:and`, `:or`, `:not`) are limited to a maximum depth
  of 10 to prevent infinite recursion and stack overflow.

  ## Error Messages

  Validation errors are returned as a list of human-readable strings:

      {:error, [
        "missing required field: id",
        "missing required field: trigger",
        "invalid action format"
      ]}

  ## Batch Validation

  Use `validate_rules/1` to validate multiple rules at once:

      case ExMaude.IoT.Validator.validate_rules(rules) do
        :ok -> proceed()
        {:error, %{"rule-1" => ["invalid trigger format"]}} -> handle_errors()
      end

  ## See Also

  - `ExMaude.IoT` - High-level conflict detection API
  - `ExMaude.IoT.Encoder` - Encoding validated rules to Maude syntax
  """

  @max_trigger_depth 10

  @doc """
  Validates a rule structure.

  Returns `:ok` if the rule is valid, or `{:error, errors}` with a list
  of validation error messages.

  ## Examples

      :ok = validate_rule(%{
        id: "my-rule",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: [{:set_prop, "device-1", "power", "on"}]
      })

      {:error, ["missing required field: id"]} = validate_rule(%{})
  """
  @spec validate_rule(map()) :: :ok | {:error, [String.t()]}
  def validate_rule(rule) when is_map(rule) do
    errors =
      []
      |> validate_required(rule, :id, "id")
      |> validate_required(rule, :thing_id, "thing_id")
      |> validate_required(rule, :trigger, "trigger")
      |> validate_required(rule, :actions, "actions")
      |> validate_trigger(rule[:trigger], 0)
      |> validate_actions(rule[:actions])

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate_rule(_), do: {:error, ["rule must be a map"]}

  @doc """
  Validates a list of rules.

  Returns `:ok` if all rules are valid, or `{:error, errors}` with a map
  of rule IDs to their validation errors.
  """
  @spec validate_rules([map()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  def validate_rules(rules) when is_list(rules) do
    errors =
      rules
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {rule, idx}, acc ->
        case validate_rule(rule) do
          :ok -> acc
          {:error, errs} -> Map.put(acc, rule[:id] || "rule_#{idx}", errs)
        end
      end)

    case errors do
      empty when map_size(empty) == 0 -> :ok
      _ -> {:error, errors}
    end
  end

  # Private validation functions

  defp validate_required(errors, map, key, name) do
    if Map.has_key?(map, key) and not is_nil(map[key]) do
      errors
    else
      ["missing required field: #{name}" | errors]
    end
  end

  # Trigger validation with depth limiting to prevent infinite recursion
  defp validate_trigger(errors, _trigger, depth) when depth > @max_trigger_depth do
    ["trigger nesting exceeds maximum depth of #{@max_trigger_depth}" | errors]
  end

  defp validate_trigger(errors, nil, _depth), do: errors

  defp validate_trigger(errors, {:prop_eq, prop, _}, _depth) when is_binary(prop), do: errors

  defp validate_trigger(errors, {:prop_gt, prop, v}, _depth)
       when is_binary(prop) and is_number(v),
       do: errors

  defp validate_trigger(errors, {:prop_lt, prop, v}, _depth)
       when is_binary(prop) and is_number(v),
       do: errors

  defp validate_trigger(errors, {:prop_gte, prop, v}, _depth)
       when is_binary(prop) and is_number(v),
       do: errors

  defp validate_trigger(errors, {:prop_lte, prop, v}, _depth)
       when is_binary(prop) and is_number(v),
       do: errors

  defp validate_trigger(errors, {:env_eq, prop, _}, _depth) when is_binary(prop), do: errors

  defp validate_trigger(errors, {:env_gt, prop, v}, _depth)
       when is_binary(prop) and is_number(v),
       do: errors

  defp validate_trigger(errors, {:env_lt, prop, v}, _depth)
       when is_binary(prop) and is_number(v),
       do: errors

  defp validate_trigger(errors, {:always}, _depth), do: errors

  defp validate_trigger(errors, {:and, t1, t2}, depth) do
    errors
    |> validate_trigger(t1, depth + 1)
    |> validate_trigger(t2, depth + 1)
  end

  defp validate_trigger(errors, {:or, t1, t2}, depth) do
    errors
    |> validate_trigger(t1, depth + 1)
    |> validate_trigger(t2, depth + 1)
  end

  defp validate_trigger(errors, {:not, t}, depth), do: validate_trigger(errors, t, depth + 1)
  defp validate_trigger(errors, _, _depth), do: ["invalid trigger format" | errors]

  defp validate_actions(errors, nil), do: errors

  defp validate_actions(errors, actions) when is_list(actions) do
    Enum.reduce(actions, errors, &validate_action/2)
  end

  defp validate_actions(errors, _), do: ["actions must be a list" | errors]

  defp validate_action({:set_prop, thing_id, prop, _}, errors)
       when is_binary(thing_id) and is_binary(prop),
       do: errors

  defp validate_action({:set_env, prop, _}, errors) when is_binary(prop), do: errors

  defp validate_action({:invoke, thing_id, action}, errors)
       when is_binary(thing_id) and is_binary(action),
       do: errors

  defp validate_action(_, errors), do: ["invalid action format" | errors]
end
