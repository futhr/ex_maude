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

      # Detect conflicts
      {:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
      # => [%{type: :state_conflict, rule1: "motion-light", rule2: "night-light", ...}]

  ## Prerequisites

  Before using conflict detection, load the IoT rules module:

      ExMaude.load_file(ExMaude.iot_rules_path())

  ## Telemetry

  This module emits the following telemetry events:

  - `[:ex_maude, :iot, :detect_conflicts, :start]` - Emitted when detection begins
  - `[:ex_maude, :iot, :detect_conflicts, :stop]` - Emitted when detection completes

  Measurements include `:duration` in native time units, `:rule_count`, and
  `:conflict_count`. Metadata includes `:result` (`:ok` or `:error`).

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  alias ExMaude.Maude
  alias ExMaude.IoT.{Encoder, ConflictParser, Validator}

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
  def detect_conflicts(rules, opts \\ []) when is_list(rules) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    rule_count = length(rules)
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ex_maude, :iot, :detect_conflicts, :start],
      %{system_time: System.system_time(), rule_count: rule_count},
      %{}
    )

    result =
      with :ok <- ensure_iot_module_loaded(),
           {:ok, maude_rules} <- Encoder.encode_rules(rules),
           {:ok, output} <- run_detection(maude_rules, timeout) do
        {:ok, ConflictParser.parse_conflicts(output)}
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
      %{result: result_atom}
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

    with :ok <- ensure_iot_module_loaded(),
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

    with :ok <- ensure_iot_module_loaded(),
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

    with :ok <- ensure_iot_module_loaded(),
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

  # Private functions

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
end
