defmodule ExMaude.AI.Validator do
  @moduledoc """
  Validates AI rule structures before encoding to Maude.

  Companion to `ExMaude.IoT.Validator`. Catches shape errors,
  unsupported predicate types, and obviously-malformed values
  before they reach the Maude port worker. Validation here is
  cheap; rejecting at this layer avoids the cost of a Maude round
  trip for a malformed rule.

  An AI rule is a map with these required fields:

    - `:id` — non-empty string
    - `:agent_id` — `{tenant_id :: String.t(), agent_name :: String.t()}`
    - `:trigger` — predicate (see Encoder docs for predicate shapes)
    - `:invocations` — list of tool invocations (may be empty)

  Optional fields:

    - `:capability_grants` — list of `{:cap, name, shape}` or bare strings
    - `:authority_required` — non-negative integer (default 0)
    - `:priority` — non-negative integer (default 1)
  """

  @doc """
  Validates a single AI rule.

  Returns `:ok` on success, or `{:error, [error_msg]}` listing all
  validation failures.

  ## Examples

      iex> ExMaude.AI.Validator.validate_rule(%{
      ...>   id: "r1",
      ...>   agent_id: {"acme", "ag-1"},
      ...>   trigger: {:always},
      ...>   invocations: []
      ...> })
      :ok

      iex> ExMaude.AI.Validator.validate_rule(%{})
      {:error,
       [
         "missing required field: id",
         "missing required field: agent_id",
         "missing required field: trigger",
         "missing required field: invocations"
       ]}

      iex> rule = %{
      ...>   id: "r1",
      ...>   agent_id: {"acme", "ag-1"},
      ...>   trigger: {:contains, "x", "y"},
      ...>   invocations: []
      ...> }
      ...>
      ...> ExMaude.AI.Validator.validate_rule(rule)
      {:error,
       ["trigger: :contains is unverifiable in ai-rules.maude (route to string-match safety net)"]}
  """
  @spec validate_rule(term()) :: :ok | {:error, [String.t()]}
  def validate_rule(rule) when is_map(rule) do
    errors =
      []
      |> validate_required_fields(rule)
      |> validate_id(rule)
      |> validate_agent_id(rule)
      |> validate_trigger(rule)
      |> validate_invocations(rule)
      |> validate_capability_grants(rule)
      |> validate_authority_required(rule)
      |> validate_priority(rule)

    case errors do
      [] -> :ok
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  def validate_rule(_), do: {:error, ["rule must be a map"]}

  @doc """
  Validates a list of rules. Returns `:ok` if all rules pass, or
  `{:error, %{rule_id => errors}}` mapping failing rule ids to
  their error lists.
  """
  @spec validate_rules([term()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  def validate_rules(rules) when is_list(rules) do
    failures =
      rules
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {rule, idx}, acc ->
        case validate_rule(rule) do
          :ok ->
            acc

          {:error, errs} ->
            id = Map.get(rule || %{}, :id) || "<index #{idx}>"
            Map.put(acc, id, errs)
        end
      end)

    if failures == %{}, do: :ok, else: {:error, failures}
  end

  defp validate_required_fields(errors, rule) do
    [:id, :agent_id, :trigger, :invocations]
    |> Enum.reduce(errors, fn field, acc ->
      if Map.has_key?(rule, field), do: acc, else: ["missing required field: #{field}" | acc]
    end)
  end

  defp validate_id(errors, %{id: id}) when is_binary(id) and id != "", do: errors
  defp validate_id(errors, %{id: _}), do: ["id must be a non-empty string" | errors]
  defp validate_id(errors, _), do: errors

  defp validate_agent_id(errors, %{agent_id: {tenant_id, agent_name}})
       when is_binary(tenant_id) and tenant_id != "" and is_binary(agent_name) and
              agent_name != "" do
    errors
  end

  defp validate_agent_id(errors, %{agent_id: _}) do
    ["agent_id must be a {tenant_id, agent_name} tuple of non-empty strings" | errors]
  end

  defp validate_agent_id(errors, _), do: errors

  defp validate_trigger(errors, %{trigger: trigger}) do
    case validate_predicate(trigger) do
      :ok -> errors
      {:error, msg} -> ["trigger: #{msg}" | errors]
    end
  end

  defp validate_trigger(errors, _), do: errors

  defp validate_invocations(errors, %{invocations: invocations}) when is_list(invocations) do
    invocations
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {inv, idx}, acc ->
      case validate_invocation(inv) do
        :ok -> acc
        {:error, msg} -> ["invocation[#{idx}]: #{msg}" | acc]
      end
    end)
  end

  defp validate_invocations(errors, %{invocations: _}) do
    ["invocations must be a list" | errors]
  end

  defp validate_invocations(errors, _), do: errors

  defp validate_capability_grants(errors, %{capability_grants: grants}) when is_list(grants) do
    grants
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {grant, idx}, acc ->
      case validate_capability(grant) do
        :ok -> acc
        {:error, msg} -> ["capability_grants[#{idx}]: #{msg}" | acc]
      end
    end)
  end

  defp validate_capability_grants(errors, %{capability_grants: _}) do
    ["capability_grants must be a list" | errors]
  end

  defp validate_capability_grants(errors, _), do: errors

  defp validate_authority_required(errors, %{authority_required: a})
       when is_integer(a) and a >= 0,
       do: errors

  defp validate_authority_required(errors, %{authority_required: _}) do
    ["authority_required must be a non-negative integer" | errors]
  end

  defp validate_authority_required(errors, _), do: errors

  defp validate_priority(errors, %{priority: p}) when is_integer(p) and p >= 0, do: errors

  defp validate_priority(errors, %{priority: _}) do
    ["priority must be a non-negative integer" | errors]
  end

  defp validate_priority(errors, _), do: errors

  @doc false
  @spec validate_predicate(term()) :: :ok | {:error, String.t()}
  def validate_predicate({:always}), do: :ok

  def validate_predicate({prop_op, key, _})
      when prop_op in [:prop_eq, :prop_gt, :prop_lt, :prop_gte, :prop_lte] and is_binary(key) do
    :ok
  end

  def validate_predicate({:capability_required, name}) when is_binary(name) and name != "",
    do: :ok

  def validate_predicate({:capability_granted, name}) when is_binary(name) and name != "", do: :ok

  def validate_predicate({:budget_within, scope, {:interval, lo, hi}})
      when is_binary(scope) and is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= lo do
    :ok
  end

  def validate_predicate({:authority_at_least, n}) when is_integer(n) and n >= 0, do: :ok
  def validate_predicate({:authority_required, n}) when is_integer(n) and n >= 0, do: :ok

  def validate_predicate({:jurisdiction_allowed, j}) when is_atom(j) and not is_nil(j), do: :ok
  def validate_predicate({:jurisdiction_forbidden, j}) when is_atom(j) and not is_nil(j), do: :ok

  def validate_predicate({:latency_at_most, ms}) when is_integer(ms) and ms >= 0, do: :ok

  def validate_predicate({:and, p1, p2}) do
    with :ok <- validate_predicate(p1) do
      validate_predicate(p2)
    end
  end

  def validate_predicate({:or, p1, p2}) do
    with :ok <- validate_predicate(p1) do
      validate_predicate(p2)
    end
  end

  def validate_predicate({:not, p}), do: validate_predicate(p)

  # Regex / contains operators are explicitly unverifiable in the
  # equational fragment of Maude. Surface that contract here so the
  # caller can route to a different safety net.
  def validate_predicate({:contains, _, _}),
    do: {:error, ":contains is unverifiable in ai-rules.maude (route to string-match safety net)"}

  def validate_predicate({:matches, _, _}),
    do: {:error, ":matches is unverifiable in ai-rules.maude (route to regex safety net)"}

  def validate_predicate(other), do: {:error, "unsupported predicate shape: #{inspect(other)}"}

  @doc false
  @spec validate_invocation(term()) :: :ok | {:error, String.t()}
  def validate_invocation({:invoke_tool, name, args, cap_required, jurisdiction})
      when is_binary(name) and name != "" and is_map(args) and is_binary(cap_required) and
             is_atom(jurisdiction) and not is_nil(jurisdiction) do
    case validate_arg_map(args) do
      :ok -> :ok
      {:error, msg} -> {:error, "invoke_tool args: #{msg}"}
    end
  end

  def validate_invocation({:require_approval, class}) when is_binary(class) and class != "",
    do: :ok

  def validate_invocation(other), do: {:error, "unsupported invocation shape: #{inspect(other)}"}

  defp validate_arg_map(args) when is_map(args) do
    Enum.reduce_while(args, :ok, fn {k, v}, _ ->
      case validate_value(v) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "key #{inspect(k)}: #{msg}"}}
      end
    end)
  end

  @doc false
  @spec validate_capability(term()) :: :ok | {:error, String.t()}
  def validate_capability({:cap, name, shape})
      when is_binary(name) and is_binary(shape) and name != "" do
    :ok
  end

  def validate_capability(name) when is_binary(name) and name != "", do: :ok

  def validate_capability(other), do: {:error, "unsupported capability shape: #{inspect(other)}"}

  @doc false
  @spec validate_value(term()) :: :ok | {:error, String.t()}
  def validate_value({:str, s}) when is_binary(s), do: :ok
  def validate_value({:int, n}) when is_integer(n), do: :ok
  def validate_value({:bool, b}) when is_boolean(b), do: :ok

  def validate_value({:interval, lo, hi})
      when is_integer(lo) and is_integer(hi) and lo >= 0 and hi >= lo,
      do: :ok

  def validate_value({:jurisdiction, j}) when is_atom(j) and not is_nil(j), do: :ok
  def validate_value(nil), do: :ok

  def validate_value(s) when is_binary(s), do: :ok
  def validate_value(n) when is_integer(n), do: :ok
  def validate_value(b) when is_boolean(b), do: :ok

  def validate_value(other), do: {:error, "unsupported value shape: #{inspect(other)}"}
end
