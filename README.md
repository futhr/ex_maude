# ExMaude

**Elixir bindings for the Maude formal verification system**

[![Hex.pm](https://img.shields.io/hexpm/v/ex_maude.svg)](https://hex.pm/packages/ex_maude) [![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_maude) [![CI](https://github.com/futhr/ex_maude/actions/workflows/ci.yml/badge.svg)](https://github.com/futhr/ex_maude/actions/workflows/ci.yml) [![Coverage](https://codecov.io/gh/futhr/ex_maude/branch/main/graph/badge.svg)](https://codecov.io/gh/futhr/ex_maude) [![License: MIT](https://img.shields.io/github/license/futhr/ex_maude)](https://opensource.org/licenses/MIT)

[Installation](#installation) |
[Quick Start](#quick-start) |
[Documentation](https://github.com/futhr/ex_maude)

---

## Overview

ExMaude provides a high-level Elixir API for interacting with [Maude](https://maude.cs.illinois.edu/),
a powerful formal specification language based on rewriting logic. Use ExMaude for:

- **Term Reduction** - Simplify expressions using equational logic
- **State Space Search** - Explore reachable states in system models  
- **Formal Verification** - Verify properties of concurrent and distributed systems
- **IoT Rule Conflict Detection** - Detect conflicts in physical-IoT automation rules
- **AI Rule Conflict Detection** - Verify multi-tenant agent policies, capability grants,
  sovereignty, authority levels, and approval gates

---

## Features

| Feature | Description |
|---------|-------------|
| **Port-based IPC** | Efficient communication via Erlang Ports |
| **Worker Pool** | Concurrent operations via Poolboy |
| **High-level API** | `reduce/3`, `rewrite/3`, `search/4`, `load_file/1` |
| **Output Parsing** | Structured parsing of Maude results |
| **Telemetry** | Built-in observability events |
| **IoT Module** | Formal conflict detection for physical-IoT automation rules |
| **AI Module** | Formal conflict detection for AI agent policies (capability, sovereignty, authority, approval) |

---

## Installation

### Requirements

- Elixir ~> 1.17
- Erlang/OTP 26+

Add `ex_maude` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_maude, "~> 0.3.0"}
  ]
end
```

Then install the Maude binary:

```bash
mix deps.get
mix maude.install
```

---

## Quick Start

```elixir
# Start the worker pool
{:ok, _} = ExMaude.Pool.start_link()

# Reduce a term to normal form
{:ok, "6"} = ExMaude.reduce("NAT", "1 + 2 + 3")

# Search state space
{:ok, solutions} = ExMaude.search("MY-MODULE", "initial", "goal", max_depth: 10)

# Load a custom module
:ok = ExMaude.load_file("/path/to/my-module.maude")
```

---

## Configuration

```elixir
config :ex_maude,
  backend: :port,                      # :port | :cnode | :nif
  maude_path: nil,                     # nil = auto-detect bundled binary
  pool_size: 4,                        # Number of worker processes
  pool_max_overflow: 2,                # Extra workers under load
  timeout: 5_000,                      # Default command timeout (ms)
  start_pool: false,                   # Auto-start pool on application start
  use_pty: true                        # Use PTY wrapper (Port backend only)
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `backend` | `atom()` | `:port` | Communication backend (`:port`, `:cnode`, `:nif`) |
| `maude_path` | `String.t()` | `nil` | Path to Maude executable (nil = bundled) |
| `pool_size` | `integer()` | `4` | Number of Maude worker processes |
| `pool_max_overflow` | `integer()` | `2` | Extra workers allowed under load |
| `timeout` | `integer()` | `5000` | Default command timeout in ms |
| `start_pool` | `boolean()` | `false` | Auto-start pool on application boot |
| `use_pty` | `boolean()` | `true` | Use PTY wrapper for Maude prompts |

Set `use_pty: false` if you encounter `script: openpty: Device not configured` errors (common in Docker/CI environments).

### Backend Selection

ExMaude bundles Maude binaries for common platforms. No installation step needed for most users.

```elixir
# Check available backends
ExMaude.Backend.available_backends()
#=> [:port]  # plus :cnode if maude_bridge is compiled, :nif if the precompiled NIF loaded

# Switch backend at runtime (for testing)
Application.put_env(:ex_maude, :backend, :cnode)
```

---

## API Reference

### Term Operations

```elixir
# Reduce using equations (deterministic)
ExMaude.reduce(module, term, opts \\ [])

# Rewrite using rules and equations
ExMaude.rewrite(module, term, opts \\ [])

# Search state space
ExMaude.search(module, initial, pattern, opts \\ [])
```

### Module Loading

```elixir
# Load from file
ExMaude.load_file("/path/to/module.maude")

# Load from string
ExMaude.load_module("""
fmod MY-NAT is
  sort MyNat .
  op zero : -> MyNat .
  op s : MyNat -> MyNat .
endfm
""")
```

### Direct Execution

```elixir
# Execute raw Maude commands
{:ok, output} = ExMaude.execute("show modules .")

# Get Maude version
{:ok, version} = ExMaude.version()
```

---

## IoT Rule Conflict Detection

ExMaude includes a Maude module implementing formal conflict detection for IoT automation rules,
based on the [AutoIoT paper](https://arxiv.org/abs/2411.10665).

```elixir
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
```

### Detected Conflict Types

| Type | Description |
|------|-------------|
| **State Conflict** | Same device, incompatible state changes |
| **Environment Conflict** | Opposing environmental effects |
| **State Cascading** | Rule output triggers conflicting rule |
| **State-Env Cascading** | Combined cascading effects |

See `ExMaude.IoT` for the full rule schema, trigger types, and action types.

---

## AI Rule Conflict Detection

ExMaude includes a Maude module for verifying AI-generated automation rules over
Agents, Capabilities, ToolInvocations, and richer predicates (capability ontology,
budget intervals, sovereignty, authority levels, approval gates). Use it to catch
unsafe agent policies before they ship.

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
  },
  %{
    id: "auto-dose",
    agent_id: {"acme", "ph-controller"},
    trigger: {:prop_lt, "ph", {:int, 5}},
    invocations: [
      {:invoke_tool, "dose", %{"ml" => 100}, "high_impact", :eu}
    ],
    priority: 1
  }
]

{:ok, conflicts} = ExMaude.AI.detect_conflicts(rules, jurisdictions: [:eu, :ch])
# => [%{type: :approval_gate_bypass, rule1: "auto-dose", rule2: nil, ...}]
```

### Detected Conflict Types

| Type | Detection | Description |
|------|-----------|-------------|
| **Tool Call Conflict** | pairwise | Same agent, same tool, conflicting required arguments |
| **Capability Shadowing** | pairwise | Two rules grant the same capability at equal priority within a tenant |
| **Pack Tool Composition Mismatch** | pairwise | Same capability name, mismatched type-shape signatures |
| **Authority Escalation** | pairwise | Rule grants a capability another rule requires at higher authority |
| **Agent Loop Cascade** | pairwise | One rule's capability grants another rule's required capability |
| **Sovereignty Violation** | single-rule | Tool invocation routes through a forbidden jurisdiction |
| **Approval Gate Bypass** | single-rule | High-impact invocation reachable without an approval gate |
| **Budget Cascade** | search-based | Chained rule firings exceed tenant budget (deferred to follow-up) |
| **Cost Ceiling Infeasibility** | search-based | Tenant policy leaves empty cost-acceptable provider set (deferred) |
| **Provider Routing Infeasibility** | search-based | Empty action space under tenant policy intersection (deferred) |

### When to choose AI rules over IoT rules

Use `ExMaude.IoT` for Things, Properties, and Actions in a single deployment
(one building, one factory, one farm). Use `ExMaude.AI` for Agents with capability
ontologies, tool-invocation arguments, tenant scoping, sovereignty, authority levels,
or approval gates. Both can coexist — the templates and APIs are independent.

### Unverifiable predicates

`:contains` and `:matches` (regex / string search) are not decidable in Maude's
equational fragment. The validator returns `{:error, "...unverifiable..."}` for
these — route them to a separate string-match safety net (sandbox, regex matcher,
LLM-as-judge) rather than encoding them into the Maude template.

See `ExMaude.AI` for the full rule schema, predicate vocabulary, and invocation types.

---

## Telemetry

ExMaude emits telemetry events compatible with Prometheus, OpenTelemetry, and other exporters.
All measurements use native time units for precision.

### Events

| Event | Description |
|-------|-------------|
| `[:ex_maude, :command, :start]` | Command execution started |
| `[:ex_maude, :command, :stop]` | Command execution completed |
| `[:ex_maude, :command, :exception]` | Command raised an exception |
| `[:ex_maude, :pool, :checkout, :start]` | Pool checkout started |
| `[:ex_maude, :pool, :checkout, :stop]` | Pool checkout completed |
| `[:ex_maude, :iot, :detect_conflicts, :start]` | IoT conflict detection started |
| `[:ex_maude, :iot, :detect_conflicts, :stop]` | IoT conflict detection completed |
| `[:ex_maude, :ai, :detect_conflicts, :start]` | AI conflict detection started |
| `[:ex_maude, :ai, :detect_conflicts, :stop]` | AI conflict detection completed |

### Measurements

- `duration` - Time in native units (convert with `System.convert_time_unit/3`)
- `system_time` - Wall clock time when event started
- `rule_count` - Number of rules (IoT and AI events)
- `conflict_count` - Conflicts detected (IoT and AI events)

### Metadata

- `operation` - Command type (`:reduce`, `:rewrite`, `:search`, `:execute`, `:parse`)
- `module` - Maude module name
- `result` - `:ok` or `:error`
- `template` - Conflict-detection template in use (`:iot_rules` or `:ai_rules`)

### Example: Prometheus Metrics

```elixir
# In your application's telemetry module
defp metrics do
  [
    counter("ex_maude.command.stop.count", tags: [:operation, :result]),
    distribution("ex_maude.command.stop.duration",
      unit: {:native, :millisecond},
      tags: [:operation, :result]
    ),
    last_value("ex_maude.iot.detect_conflicts.stop.conflict_count")
  ]
end
```

### Example: Custom Handler

```elixir
:telemetry.attach(
  "my-logger",
  [:ex_maude, :command, :stop],
  fn _, %{duration: d}, %{operation: op, result: r}, _ ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.info("ExMaude #{op}: #{r} in #{ms}ms")
  end,
  nil
)
```

For complete event documentation, see `ExMaude.Telemetry`.

---

## Architecture

ExMaude uses a pluggable backend architecture, allowing different communication strategies:

```
                        ExMaude (Public API)
                              │
                    ExMaude.Backend (Behaviour)
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
ExMaude.Backend.Port   ExMaude.Backend.CNode   ExMaude.Backend.NIF
        │                     │                     │
        ▼                     ▼                     ▼
   PTY + Maude CLI    Erlang Distribution    Direct libmaude
                      + maude_bridge          via Rustler
```

| Backend | Isolation | Latency | Use Case |
|---------|-----------|---------|----------|
| **Port** | Full | Higher | Default, safe, works everywhere |
| **C-Node** | Full | Medium | Production, structured data |
| **NIF** | None | Lowest | Hot paths, after profiling |

### Module Overview

```
ExMaude
    ├── ExMaude.Backend    Backend behaviour and selection
    ├── ExMaude.Binary     Binary lookup, platform detection, bundled binaries
    ├── ExMaude.Maude      High-level command builders (reduce, rewrite, search)
    ├── ExMaude.Pool       Poolboy worker pool management
    ├── ExMaude.Server     Per-worker GenServer wrapping a backend session
    ├── ExMaude.Parser     Output parsing utilities
    ├── ExMaude.Telemetry  Telemetry events and helpers
    ├── ExMaude.IoT        IoT rule conflict detection (Things, Properties, Actions)
    └── ExMaude.AI         AI rule conflict detection (Agents, Capabilities, Invocations)
```

---

## Development

```bash
mix setup # Setup
mix test  # Run tests
mix check # Run all quality checks
mix docs  # Generate documentation
```

### Running Benchmarks

```bash
mix bench              # Parser benchmarks
mix bench.backends     # Backend benchmarks (Port backend only)
mix bench.backends.all # Backend benchmarks (All backends: Port + C-Node)
```

**C-Node Testing:**
```bash
mix test.cnode # Run C-Node integration tests
```

**Note:** C-Node requires:
1. Compiled binary: `cd c_src && make`
2. The `mix bench.backends.all` and `mix test.cnode` aliases automatically handle Erlang distribution

---

## Performance

ExMaude includes comprehensive benchmarks to help you understand performance characteristics and choose the right backend for your workload.

### Benchmark Results

- **[bench/output/benchmarks.md](bench/output/benchmarks.md)** - Parser and Maude integration benchmarks
- **[bench/output/backend_comparison.md](bench/output/backend_comparison.md)** - Port vs C-Node backend comparison

### Key Takeaways

| Backend | Latency | Use Case |
|---------|---------|----------|
| **Port** | ~107μs/op | Default, works everywhere, full isolation |
| **C-Node** | ~100μs/op | Production, high-throughput workloads |
| **NIF** | ~40μs/op | Hot paths, latency-critical workloads |

> Latency figures are `reduce in NAT : 1 + 1` on Apple Silicon (M-series),
> averaged over 200 warm iterations. Run the benchmarks locally for your
> hardware.

**Recommendation:** Start with Port backend, switch to C-Node if benchmarks show communication overhead is a bottleneck.

### Running Benchmarks

See [Development](#development) section for benchmark commands.

---

## Interactive Notebooks

Explore ExMaude interactively with Livebook:

| Notebook | Description | Livebook |
|----------|-------------|----------|
| [Quick Start](notebooks/quickstart.livemd) | Basic usage and examples | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fquickstart.livemd) |
| [Advanced Usage](notebooks/advanced.livemd) | IoT conflicts, custom modules, pooling | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fadvanced.livemd) |
| [AI Rules](notebooks/ai-rules.livemd) | AI agent policy conflict detection | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fai-rules.livemd) |
| [Term Rewriting](notebooks/rewriting.livemd) | Rewriting and search deep dive | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Frewriting.livemd) |
| [Benchmarks](notebooks/benchmarks.livemd) | Performance metrics | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fbenchmarks.livemd) |

---

## Documentation

- [GitHub](https://github.com/futhr/ex_maude) - Documentation and source code
- [AGENTS.md](AGENTS.md) - AI agent integration guide

---

## References

- [Maude System](https://maude.cs.illinois.edu/) - Official Maude website
- [Maude Manual](https://maude.lcc.uma.es/maude-manual/) - Complete documentation
- [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - IoT conflict detection research
- [Haskell Maude Bindings](https://hackage.haskell.org/package/maude) - Reference implementation

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## License

ExMaude is released under the MIT License. See [LICENSE](LICENSE) for details.
