# ExMaude Usage Rules

Guidelines for AI agents and developers working with ExMaude - Elixir bindings for the Maude formal verification system.

## Overview

ExMaude provides a high-level Elixir API for interacting with Maude, a formal specification language based on rewriting logic. It manages Maude processes via Erlang Ports with a Poolboy worker pool.

## Core Concepts

### Maude Operations

- **reduce** - Apply equations to simplify a term to normal form (deterministic)
- **rewrite** - Apply rules and equations (may be non-deterministic)
- **search** - Explore state space to find states matching a pattern
- **load_file** - Load a Maude module file into all workers

### Module Types in Maude

- `fmod ... endfm` - Functional modules with equations only
- `mod ... endm` - System modules with rules and equations

## API Usage

### Reducing Terms

```elixir
# GOOD: Use reduce for deterministic computation
{:ok, "6"} = ExMaude.reduce("NAT", "1 + 2 + 3")

# GOOD: Handle errors
case ExMaude.reduce("NAT", term) do
  {:ok, result} -> process(result)
  {:error, %ExMaude.Error{type: :parse_error}} -> handle_parse_error()
  {:error, %ExMaude.Error{type: :timeout}} -> retry_or_fail()
end

# BAD: Ignoring errors
{:ok, result} = ExMaude.reduce("NAT", user_input)  # Will crash on error
```

### Rewriting Terms

```elixir
# GOOD: Set max_rewrites to prevent infinite loops
{:ok, result} = ExMaude.rewrite("MY-MOD", "initial", max_rewrites: 100)

# BAD: Unlimited rewrites on potentially non-terminating rules
{:ok, result} = ExMaude.rewrite("MY-MOD", "initial")
```

### Searching State Space

```elixir
# GOOD: Set reasonable bounds
{:ok, solutions} = ExMaude.search("MY-MOD", "init", "goal",
  max_depth: 10,
  max_solutions: 5,
  timeout: 30_000
)

# GOOD: Use appropriate search arrows
# =>1  exactly one step
# =>+  one or more steps  
# =>*  zero or more steps (default)
# =>!  to normal form only

# BAD: Unbounded search can hang
{:ok, solutions} = ExMaude.search("MY-MOD", "init", "goal")
```

### Loading Modules

```elixir
# GOOD: Check file exists or handle error
case ExMaude.load_file(path) do
  :ok -> :loaded
  {:error, %ExMaude.Error{type: :file_not_found}} -> create_or_fail()
end

# GOOD: Load from string for dynamic modules
ExMaude.load_module("""
fmod MY-MOD is
  sort Foo .
  op bar : -> Foo .
endfm
""")

# GOOD: Use bundled IoT module
:ok = ExMaude.load_file(ExMaude.iot_rules_path())
```

## IoT Conflict Detection

ExMaude includes an equational conflict model for IoT automation rules.

### Using the High-Level API

```elixir
# GOOD: Use ExMaude.IoT module for conflict detection
rules = [
  %{
    id: "motion-light",
    thing_id: "light-1",
    trigger: {:prop_eq, "motion", true},
    actions: [{:set_prop, "light-1", "state", "on"}],
    priority: 1
  },
  %{
    id: "night-mode",
    thing_id: "light-1",
    trigger: {:prop_gt, "time", 2300},
    actions: [{:set_prop, "light-1", "state", "off"}],
    priority: 1
  }
]

{:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)

# GOOD: Validate rules before detection
:ok = ExMaude.IoT.validate_rule(rule)
{:error, errors} = ExMaude.IoT.validate_rule(%{})
```

### Conflict Types

- **state_conflict** - Same device, incompatible state changes
- **env_conflict** - Opposing environmental effects
- **state_cascade** - Rule output triggers another rule
- **state_env_cascade** - Combined state-environment cascading

### Rule Structure

```elixir
# Rule map structure
%{
  id: String.t(),           # Required: unique identifier
  thing_id: String.t(),     # Required: target device
  trigger: trigger(),       # Required: condition
  actions: [action()],      # Required: list of actions
  priority: integer()       # Optional: defaults to 1
}

# Trigger types
{:prop_eq, property, value}
{:prop_gt, property, number}
{:prop_lt, property, number}
{:env_eq, property, value}
{:always}
{:and, trigger, trigger}
{:or, trigger, trigger}
{:not, trigger}

# Action types
{:set_prop, thing_id, property, value}
{:set_env, property, value}
{:invoke, thing_id, action_name}
```

## Structured Types

### ExMaude.Term

```elixir
# Parse Maude output into structured term
{:ok, term} = ExMaude.Term.parse("result Nat: 42")
term.value  #=> "42"
term.sort   #=> "Nat"

# Convert to Elixir types
{:ok, 42} = ExMaude.Term.to_integer(term)
{:ok, true} = ExMaude.Term.to_boolean(bool_term)
```

### ExMaude.Error

```elixir
# Errors are structured with type and message
%ExMaude.Error{
  type: :parse_error | :module_not_found | :timeout | :maude_crash | ...,
  message: String.t(),
  details: map() | nil
}

# Check if error is recoverable
ExMaude.Error.recoverable?(error)  #=> true for :timeout, :maude_crash
```

## Configuration

```elixir
# config/config.exs
config :ex_maude,
  maude_path: "/usr/local/bin/maude",  # Path to Maude binary
  pool_size: 4,                        # Worker processes
  pool_max_overflow: 2,                # Extra workers under load
  timeout: 5_000,                      # Default command timeout (ms)
  preload_modules: []                  # Modules to load on startup
```

## Pool Management

```elixir
# GOOD: the host owns placement, lifecycle, and configuration
children = [
  ExMaude.Pool.child_spec(name: :verification_pool, pool_size: 4)
]

# GOOD: Let the pool manage workers automatically
{:ok, result} = ExMaude.reduce("NAT", "1 + 2")

# GOOD: Use transaction for multiple operations on same worker
ExMaude.Pool.transaction(fn worker ->
  ExMaude.Server.load_file(worker, path)
  ExMaude.Server.execute(worker, "reduce in MY-MOD : term .")
end, pool: :verification_pool)

# GOOD: Broadcast to all workers for module loading
{:ok, results} = ExMaude.Pool.broadcast(fn worker ->
  ExMaude.Server.load_file(worker, path)
end)
```

## Backend Selection

ExMaude provides three backends with different deployment requirements:

```elixir
config :ex_maude, backend: :port    # default — text I/O, full process isolation
config :ex_maude, backend: :cnode   # C bridge over Erlang distribution
config :ex_maude, backend: :nif     # Rustler NIF managing subprocess pipes
```

| Backend | When to choose it |
|---|---|
| `:port` | Default. Safest. Works on any platform with a Maude binary. Maude crash never affects the BEAM. |
| `:cnode` | Uses a C bridge and Erlang distribution. Requires `epmd` and the compiled bridge; benchmark it against Port for the target workload. |
| `:nif` | Native code drives the Maude subprocess through pipes. A native crash can crash the VM even though Maude itself remains a subprocess. |

Precompiled NIF binaries are published on Hex for macOS aarch64/x86_64, Linux gnu/musl × aarch64/x86_64, and Windows gnu/msvc. On platforms outside that list, force a local build:

```bash
EX_MAUDE_BUILD=1 mix deps.compile ex_maude
```

Verify availability at runtime:

```elixir
ExMaude.Backend.available_backends()
#=> [:port, :cnode, :nif]
```

## Error Handling Patterns

```elixir
# GOOD: Pattern match on error types
case ExMaude.reduce("MOD", term) do
  {:ok, result} -> 
    {:ok, result}
  {:error, %ExMaude.Error{type: :timeout}} -> 
    {:error, :retry_later}
  {:error, %ExMaude.Error{type: :parse_error, message: msg}} -> 
    {:error, {:invalid_term, msg}}
  {:error, %ExMaude.Error{type: :module_not_found}} -> 
    {:error, :load_module_first}
  {:error, error} -> 
    {:error, error}
end

# GOOD: Use recoverable? for retry logic
if ExMaude.Error.recoverable?(error) do
  retry(operation)
else
  fail(error)
end
```

## Testing

```elixir
# Integration tests require Maude
# Tag with @moduletag :integration or @tag :integration

defmodule MyTest do
  use ExMaude.MaudeCase
  
  @moduletag :integration
  
  test "reduces term", %{maude_available: true} do
    {:ok, "6"} = ExMaude.reduce("NAT", "1 + 2 + 3")
  end
end

# Run integration tests
# mix test --include integration
```

## Common Mistakes

### Don't construct Maude syntax manually when APIs exist

```elixir
# BAD: Manual Maude command construction
ExMaude.execute("reduce in CONFLICT-DETECTOR : detectConflicts(...) .")

# GOOD: Use the IoT API
ExMaude.IoT.detect_conflicts(rules)
```

### Don't ignore timeouts

```elixir
# BAD: Default timeout may be too short for complex operations
ExMaude.search("MOD", "init", "goal")

# GOOD: Set appropriate timeout
ExMaude.search("MOD", "init", "goal", timeout: 60_000)
```

### Don't forget to load modules

```elixir
# BAD: Using module before loading
ExMaude.reduce("MY-CUSTOM-MOD", term)  # Will fail

# GOOD: Load first
:ok = ExMaude.load_file("my-custom-mod.maude")
{:ok, result} = ExMaude.reduce("MY-CUSTOM-MOD", term)
```

## AI Rules (v0.2.0+)

`ExMaude.AI` is the parallel API to `ExMaude.IoT` for AI-generated
rules over Agents, Capabilities, ToolInvocations, and richer
predicates. It targets the bundled `priv/maude/ai-rules.maude`
template.

### Supported predicate shapes

```elixir
# Property-style (carry-over from iot-rules)
{:prop_eq, "key", value}
{:prop_gt, "key", value}
{:prop_lt, "key", value}
{:prop_gte, "key", value}
{:prop_lte, "key", value}

# Capability ontology
{:capability_required, "name"}
{:capability_granted, "name"}

# Interval-valued predicate encoding (no budget conflict detector yet)
{:budget_within, "scope", {:interval, lo, hi}}

# Authority levels
{:authority_at_least, n}
{:authority_required, n}

# Sovereignty
{:jurisdiction_allowed, :eu}
{:jurisdiction_forbidden, :us}

# Latency
{:latency_at_most, ms}

# Logical operators
{:always}
{:and, p1, p2}
{:or, p1, p2}
{:not, p}
```

### Tool invocations

```elixir
# Direct tool invocation
{:invoke_tool, "tool_name", %{"arg" => value}, "capability_required", :eu}

# Approval gate — must precede high_impact invocations
{:require_approval, "approval_class"}
```

### Conflict types detected

| Type | Detection |
|------|-----------|
| `:tool_call_conflict` | equational, pairwise |
| `:capability_shadowing` | equational, pairwise |
| `:pack_tool_composition_mismatch` | equational, pairwise |
| `:sovereignty_violation` | equational, single-rule |
| `:approval_gate_bypass` | equational, single-rule |
| `:authority_escalation` | equational, pairwise |
| `:agent_loop_cascade` | equational, pairwise |

### Example

```elixir
rules = [
  %{
    id: "approve-then-dose",
    agent_id: {"acme", "ph-controller"},
    trigger: {:prop_lt, "ph", {:int, 6}},
    invocations: [
      {:require_approval, "dosing_high_delta"},
      {:invoke_tool, "dose", %{"ml" => 50}, "high_impact", :eu}
    ],
    capability_grants: [{:cap, "ph_dosing", "v1"}],
    authority_required: 2,
    priority: 1
  }
]

{:ok, conflicts} = ExMaude.AI.detect_conflicts(rules, jurisdictions: [:eu, :ch])
```

### When to choose AI rules over IoT rules

Use `ExMaude.IoT` when modelling Things, Properties, and Actions
in a single deployment (one building, one factory, one farm).
Use `ExMaude.AI` when modelling Agents with capability ontologies,
tool-invocation argument structure, tenant scoping, sovereignty,
authority levels, or approval gates. Both can ship in the same
application — the templates and APIs are independent.

### Unsupported predicates

`:contains` and `:matches` are decidable operations, but this Maude template
does not implement them. The validator returns an unsupported-predicate error;
evaluate them in the component that defines the intended string/regex semantics.

## Links

- [ExMaude HexDocs](https://hexdocs.pm/ex_maude)
- [Maude System](https://maude.cs.illinois.edu/)
- [Maude Manual](https://maude.lcc.uma.es/maude-manual/)
- [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - IoT conflict detection research
