defmodule ExMaude.IoT do
  @moduledoc """
  IoT rule conflict detection using Maude formal verification.

  This module provides an Elixir API for detecting conflicts in IoT automation
  rules using Maude's formal verification capabilities. It implements the four
  conflict types identified in the AutoIoT paper (arxiv.org/abs/2411.10665):

  ## Conflict Types

  1. **State Conflict** - Two rules target the same device property with
     incompatible values. Example: motion sensor turns light on while
     time-based rule turns it off.

  2. **Environment Conflict** - Two rules produce opposing environmental
     effects. Example: one rule opens a window to cool, another closes it
     to reduce noise.

  3. **State Cascade** - A rule's output triggers another rule, creating
     unexpected chains. Example: door open → light on → play sound →
     light off creates oscillation.

  4. **State-Environment Cascade** - Combined state and environment effects
     cascade through multiple rules. Example: AC on → window closes →
     CO2 rises → window opens → conflicts with AC.

  ## Usage

      # Define rules
      rules = [
        %{
          id: "motion-light",
          thing_id: "light-1",
          trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}],
          priority: 1
        },
        %{
          id: "night-light",
          thing_id: "light-1",
          trigger: {:prop_gt, "time", 2300},
          actions: [{:set_prop, "light-1", "state", "off"}],
          priority: 1
        }
      ]

      # Detect conflicts (the bundled iot-rules.maude module is loaded
      # automatically on first call)
      {:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
      # => [%{type: :state_conflict, rule1: "motion-light", rule2: "night-light", ...}]

  ## Telemetry

  This module emits the following telemetry events:

  - `[:ex_maude, :iot, :detect_conflicts, :start]` - Emitted when detection begins
  - `[:ex_maude, :iot, :detect_conflicts, :stop]` - Emitted when detection completes

  Measurements include `:duration` in native time units, `:rule_count`, and
  `:conflict_count`. Metadata includes `:result` (`:ok` or `:error`) and
  `:template` (`:iot_rules`).

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  alias ExMaude.IoT.{ConflictParser, Encoder, Validator}
  alias ExMaude.Maude

  @type thing_id :: String.t()

  @type trigger ::
          {:prop_eq, String.t(), term()}
          | {:prop_gt, String.t(), number()}
          | {:prop_lt, String.t(), number()}
          | {:prop_gte, String.t(), number()}
          | {:prop_lte, String.t(), number()}
          | {:env_eq, String.t(), term()}
          | {:env_gt, String.t(), number()}
          | {:env_lt, String.t(), number()}
          | {:always}
          | {:and, trigger(), trigger()}
          | {:or, trigger(), trigger()}
          | {:not, trigger()}

  @type action ::
          {:set_prop, thing_id(), String.t(), term()}
          | {:set_env, String.t(), term()}
          | {:invoke, thing_id(), String.t()}

  @type rule :: %{
          required(:id) => String.t(),
          required(:thing_id) => thing_id(),
          required(:trigger) => trigger(),
          required(:actions) => [action()],
          optional(:priority) => non_neg_integer()
        }

  @type conflict_type :: :state_conflict | :env_conflict | :state_cascade | :state_env_cascade
  @conflict_types [:state_conflict, :env_conflict, :state_cascade, :state_env_cascade]

  @type conflict :: %{
          type: conflict_type(),
          rule1: String.t(),
          rule2: String.t(),
          reason: String.t()
        }

  @doc """
  Detects all conflicts in a set of IoT rules.

  Analyzes the given rules for all four conflict types using Maude formal
  verification. Returns a list of detected conflicts, or an empty list if
  no conflicts are found.

  ## Examples

      rules = [
        %{id: "r1", thing_id: "light-1", trigger: {:prop_eq, "motion", true},
          actions: [{:set_prop, "light-1", "state", "on"}], priority: 1},
        %{id: "r2", thing_id: "light-1", trigger: {:prop_gt, "time", 2300},
          actions: [{:set_prop, "light-1", "state", "off"}], priority: 1}
      ]

      {:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
      [%{type: :state_conflict, rule1: "r1", rule2: "r2", reason: _}] = conflicts

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 10000)
    * `:conflict_types` - List of conflict types to check (default: all)
  """
  @spec detect_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    rule_count = if is_list(rules), do: length(rules), else: 0
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ex_maude, :iot, :detect_conflicts, :start],
      %{system_time: System.system_time(), rule_count: rule_count},
      %{template: :iot_rules}
    )

    result =
      with :ok <- Validator.validate_rules(rules),
           :ok <- ensure_iot_module_loaded(),
           {:ok, maude_rules} <- Encoder.encode_rules(rules),
           {:ok, output} <- run_detection(maude_rules, timeout) do
        conflicts = ConflictParser.parse_conflicts(output)
        filter_conflicts(conflicts, Keyword.get(opts, :conflict_types))
      end

    duration = System.monotonic_time() - start_time

    {result_atom, conflict_count} =
      case result do
        {:ok, conflicts} -> {:ok, length(conflicts)}
        {:error, _} -> {:error, 0}
      end

    :telemetry.execute(
      [:ex_maude, :iot, :detect_conflicts, :stop],
      %{duration: duration, conflict_count: conflict_count},
      %{result: result_atom, template: :iot_rules}
    )

    result
  end

  @doc """
  Detects only state conflicts in a set of rules.

  State conflicts occur when two rules target the same device property
  with incompatible values.

  ## Examples

      {:ok, conflicts} = ExMaude.IoT.detect_state_conflicts(rules)
  """
  @spec detect_state_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_state_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_iot_module_loaded(),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command = "reduce in CONFLICT-DETECTOR : detectConflicts(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, timeout: timeout) do
      {:ok, ConflictParser.parse_conflicts(output)}
    end
  end

  @doc """
  Detects only environment conflicts in a set of rules.

  Environment conflicts occur when two rules produce opposing
  environmental effects.
  """
  @spec detect_env_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_env_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_iot_module_loaded(),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command = "reduce in CONFLICT-DETECTOR : detectEnvConflicts(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, timeout: timeout) do
      {:ok, ConflictParser.parse_conflicts(output)}
    end
  end

  @doc """
  Detects cascade conflicts (both state and state-environment).

  Cascade conflicts occur when one rule's output triggers another rule.
  """
  @spec detect_cascade_conflicts([rule()], keyword()) :: {:ok, [conflict()]} | {:error, term()}
  def detect_cascade_conflicts(rules, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with :ok <- Validator.validate_rules(rules),
         :ok <- ensure_iot_module_loaded(),
         {:ok, maude_rules} <- Encoder.encode_rules(rules),
         command = "reduce in CONFLICT-DETECTOR : detectCascades(#{maude_rules}) .",
         {:ok, output} <- Maude.execute(command, timeout: timeout) do
      {:ok, ConflictParser.parse_conflicts(output)}
    end
  end

  @doc """
  Validates a rule structure without sending it to Maude.

  Returns `:ok` if the rule is valid, or `{:error, errors}` with a list
  of validation error messages.

  ## Examples

      :ok = ExMaude.IoT.validate_rule(%{
        id: "my-rule",
        thing_id: "device-1",
        trigger: {:prop_eq, "state", true},
        actions: [{:set_prop, "device-1", "power", "on"}]
      })

      {:error, ["missing required field: id"]} = ExMaude.IoT.validate_rule(%{})
  """
  @spec validate_rule(rule()) :: :ok | {:error, [String.t()]}
  defdelegate validate_rule(rule), to: Validator

  @doc """
  Validates a list of rules.

  Returns `:ok` if all rules are valid, or `{:error, errors}` with a map
  of rule IDs to their validation errors.
  """
  @spec validate_rules([rule()]) :: :ok | {:error, %{String.t() => [String.t()]}}
  defdelegate validate_rules(rules), to: Validator

  @typedoc """
  A predicate over a world state: a device property holding a value, or an
  environment key holding a value.
  """
  @type state_pred ::
          {:thing_state, thing_id(), String.t(), term()}
          | {:env_state, String.t(), term()}

  @typedoc """
  Options for the state-space verification functions.

    * `:initial_state` - bindings present before any rule fires (default `[]`)
    * `:max_depth` - bound on search depth (default `50`); unbounded searches
      that hit the bound return `{:ok, :unverified}` rather than blocking
    * `:timeout` - per-search timeout in ms (default `30_000`)
  """
  @type world_opts :: [
          initial_state: [state_pred()],
          max_depth: pos_integer(),
          timeout: timeout()
        ]

  @doc """
  Bounded safety check: proves no execution of `rules` reaches a world matching
  `bad_state`.

  Explores the rule-firing transition system (the `IOT-EXEC` Maude module) from
  the initial state with `=>*` reachability search, looking for a reachable
  world whose state contains `bad_state`.

  Returns:

    * `{:error, {:counterexample, solutions}}` - a reachable bad world (the
      `solutions` carry the matching state/substitution)
    * `{:ok, :unverified}` - no counterexample was found within the bound, or
      Maude was unavailable/timed out. A bounded prefix is not a safety proof.
    * `{:error, %ExMaude.Error{}}` - the verification itself failed (e.g.
      a rule that doesn't encode to valid Maude, or a missing module);
      surfaced as an error rather than `:unverified` because it indicates a
      bug in the input, not an inconclusive search

  `bad_state` is a `state_pred` or a list of them (a list means "all present in
  the same reachable world").

  ## Examples

      # Rule drives a door into an error state when motion is detected.
      rules = [%{id: "r1", thing_id: "door", trigger: {:prop_eq, "motion", true},
                 actions: [{:set_prop, "door", "state", "error"}], priority: 1}]

      ExMaude.IoT.verify_safety(rules, {:thing_state, "door", "state", "error"},
        initial_state: [{:thing_state, "door", "motion", true}])
      #=> {:error, {:counterexample, [_ | _]}}
  """
  @spec verify_safety([rule()], state_pred() | [state_pred()], world_opts()) ::
          {:ok, :unverified}
          | {:error, {:counterexample, [map()]} | ExMaude.Error.t() | term()}
  def verify_safety(rules, bad_state, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 50)
    timeout = Keyword.get(opts, :timeout, 30_000)

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_world_inputs(bad_state, opts),
         :ok <- ensure_iot_module_loaded(),
         {:ok, init} <- build_world(rules, opts),
         pattern = bad_state_pattern(bad_state),
         {:ok, solutions} <-
           Maude.search("IOT-EXEC", init, pattern,
             arrow: "=>*",
             max_solutions: 1,
             max_depth: max_depth,
             timeout: timeout
           ) do
      case solutions do
        [] -> {:ok, :unverified}
        [_ | _] -> {:error, {:counterexample, solutions}}
      end
    else
      {:error, err} -> verification_failure(err)
    end
  end

  @doc """
  Bounded liveness check: looks for a deadlock that prevents `rules` from
  reaching `goal_state`.

  Searches for a terminal world (`=>!`, no rule can fire) in which `goal_state`
  does not hold. Because the search only inspects terminal states, this detects
  deadlocks (the system stops short of the goal); it does not detect livelocks
  (infinite progress that never reaches the goal), which need full LTL model
  checking.

  Returns:

    * `{:error, :deadlock_possible}` - a reachable terminal world misses the goal
    * `{:ok, :unverified}` - no counterexample was found within the bound, or
      Maude was unavailable/timed out. This is not an unbounded liveness proof.
    * `{:error, %ExMaude.Error{}}` - the verification itself failed (invalid
      rule encoding, missing module, ...)

  ## Examples

      ExMaude.IoT.verify_liveness(rules, {:thing_state, "door", "state", "notified"})
      #=> {:ok, :unverified}
  """
  @spec verify_liveness([rule()], state_pred(), world_opts()) ::
          {:ok, :unverified}
          | {:error, :deadlock_possible | ExMaude.Error.t() | term()}
  def verify_liveness(rules, goal_state, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 50)
    timeout = Keyword.get(opts, :timeout, 30_000)

    with :ok <- Validator.validate_rules(rules),
         :ok <- validate_world_inputs(goal_state, opts),
         :ok <- ensure_iot_module_loaded(),
         {:ok, init} <- build_world(rules, opts),
         condition = goal_violation_condition(goal_state),
         {:ok, solutions} <-
           Maude.search("IOT-EXEC", init, "world(S:WState, RS:RuleSet)",
             arrow: "=>!",
             condition: condition,
             max_solutions: 1,
             max_depth: max_depth,
             timeout: timeout
           ) do
      case solutions do
        [] -> {:ok, :unverified}
        [_ | _] -> {:error, :deadlock_possible}
      end
    else
      {:error, err} -> verification_failure(err)
    end
  end

  # Absence of an answer — pool down, worker missing, command deadline — is
  # not evidence either way and maps to the documented {:ok, :unverified}.
  # Anything else (a rule that encodes to invalid Maude, a missing module,
  # a syntax error) is a bug in the input or this library and must surface
  # as an error rather than masquerade as an inconclusive verification.
  defp verification_failure(%ExMaude.Error{type: type})
       when type in [:timeout, :pool_error, :not_connected],
       do: {:ok, :unverified}

  defp verification_failure(err), do: {:error, err}

  defp build_world(rules, opts) do
    with {:ok, rule_set} <- Encoder.encode_rules(rules) do
      state = build_state(Keyword.get(opts, :initial_state, []))
      {:ok, "world(#{state}, #{rule_set})"}
    end
  end

  defp build_state([]), do: "emptyS"
  defp build_state(preds), do: Enum.map_join(preds, " ", &encode_binding/1)

  defp encode_binding({:thing_state, thing_id, property, value}) do
    "pb(#{Encoder.encode_thing_id(thing_id)}, #{Encoder.encode_string(property)}, #{Encoder.encode_value(value)})"
  end

  defp encode_binding({:env_state, key, value}) do
    "eb(#{Encoder.encode_string(key)}, #{Encoder.encode_value(value)})"
  end

  defp bad_state_pattern(preds) when is_list(preds) do
    "world(#{Enum.map_join(preds, " ", &encode_binding/1)} S:WState, RS:RuleSet)"
  end

  defp bad_state_pattern(pred), do: bad_state_pattern([pred])

  defp goal_violation_condition({:thing_state, thing_id, property, value}) do
    term = "propEq(#{Encoder.encode_string(property)}, #{Encoder.encode_value(value)})"
    "holdsFor(#{term}, #{Encoder.encode_thing_id(thing_id)}, S:WState) =/= true"
  end

  defp goal_violation_condition({:env_state, key, value}) do
    term = "envEq(#{Encoder.encode_string(key)}, #{Encoder.encode_value(value)})"
    ~s|holdsFor(#{term}, thing(""), S:WState) =/= true|
  end

  defp validate_world_inputs(predicate, opts) do
    initial_state = Keyword.get(opts, :initial_state, [])
    max_depth = Keyword.get(opts, :max_depth, 50)
    timeout = Keyword.get(opts, :timeout, 30_000)

    cond do
      not (is_integer(max_depth) and max_depth > 0) ->
        validation_error("max_depth must be a positive integer")

      not (is_integer(timeout) and timeout > 0) ->
        validation_error("timeout must be a positive integer")

      not is_list(initial_state) ->
        validation_error("initial_state must be a list of state predicates")

      not Enum.all?(initial_state, &valid_state_pred?/1) ->
        validation_error("initial_state contains an invalid state predicate")

      not Enum.all?(List.wrap(predicate), &valid_state_pred?/1) ->
        validation_error("verification target contains an invalid state predicate")

      true ->
        :ok
    end
  end

  defp valid_state_pred?({:thing_state, thing_id, property, value}) do
    non_empty_string?(thing_id) and non_empty_string?(property) and encodable_value?(value)
  end

  defp valid_state_pred?({:env_state, key, value}) do
    non_empty_string?(key) and encodable_value?(value)
  end

  defp valid_state_pred?(_), do: false

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp encodable_value?(value) do
    is_boolean(value) or is_number(value) or is_binary(value) or is_atom(value)
  end

  defp validation_error(message) do
    {:error, ExMaude.Error.new(:validation, message)}
  end

  defp ensure_iot_module_loaded do
    path = ExMaude.iot_rules_path()

    if File.exists?(path) do
      ExMaude.load_file(path)
    else
      {:error, {:module_not_found, path}}
    end
  end

  defp run_detection(maude_rules, timeout) do
    command = "reduce in CONFLICT-DETECTOR : detectAllConflicts(#{maude_rules}) ."
    Maude.execute(command, timeout: timeout)
  end

  defp filter_conflicts(conflicts, nil), do: {:ok, conflicts}

  defp filter_conflicts(conflicts, types) when is_list(types) do
    if Enum.all?(types, &(&1 in @conflict_types)) do
      {:ok, Enum.filter(conflicts, &(&1.type in types))}
    else
      validation_error("conflict_types contains an unsupported conflict type")
    end
  end

  defp filter_conflicts(_, _), do: validation_error("conflict_types must be a list")
end
