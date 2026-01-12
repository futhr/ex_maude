<div align="center">

# ExMaude

**Elixir bindings for the Maude formal verification system**

[![Hex.pm](https://img.shields.io/hexpm/v/ex_maude.svg?style=flat-square)](https://hex.pm/packages/ex_maude) [![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg?style=flat-square)](https://hexdocs.pm/ex_maude) [![CI](https://github.com/futhr/ex_maude/actions/workflows/ci.yml/badge.svg)](https://github.com/futhr/ex_maude/actions/workflows/ci.yml) [![Coverage Status](https://coveralls.io/repos/github/futhr/ex_maude/badge.svg?branch=main)](https://coveralls.io/github/futhr/ex_maude?branch=main) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)

[Installation](#installation) |
[Quick Start](#quick-start) |
[Documentation](https://hexdocs.pm/ex_maude)

</div>

---

## Overview

ExMaude provides a high-level Elixir API for interacting with [Maude](https://maude.cs.illinois.edu/),
a powerful formal specification language based on rewriting logic. Use ExMaude for:

- **Term Reduction** - Simplify expressions using equational logic
- **State Space Search** - Explore reachable states in system models  
- **Formal Verification** - Verify properties of concurrent and distributed systems
- **IoT Rule Conflict Detection** - Detect conflicts in automation rules

---

## Features

| Feature | Description |
|---------|-------------|
| **Port-based IPC** | Efficient communication via Erlang Ports |
| **Worker Pool** | Concurrent operations via Poolboy |
| **High-level API** | `reduce/3`, `rewrite/3`, `search/4`, `load_file/1` |
| **Output Parsing** | Structured parsing of Maude results |
| **Telemetry** | Built-in observability events |
| **IoT Module** | Formal conflict detection for automation rules |

---

## Installation

### Requirements

- Elixir ~> 1.17
- Erlang/OTP 26+

Add `ex_maude` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_maude, "~> 0.1.0"}
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
#=> [:port]  # or [:port, :cnode] if C-Node is compiled

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
# Load the IoT conflict detection module
:ok = ExMaude.load_file(ExMaude.iot_rules_path())

# Check for conflicts
{:ok, result} = ExMaude.reduce("CONFLICT-DETECTOR", """
  detectConflicts(
    rule("r1", thing("light"), always, setProp(thing("light"), "on", true) ; nil, 1),
    rule("r2", thing("light"), always, setProp(thing("light"), "on", false) ; nil, 1)
  )
""")
```

### Detected Conflict Types

| Type | Description |
|------|-------------|
| **State Conflict** | Same device, incompatible state changes |
| **Environment Conflict** | Opposing environmental effects |
| **State Cascading** | Rule output triggers conflicting rule |
| **State-Env Cascading** | Combined cascading effects |

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
| `[:ex_maude, :iot, :detect_conflicts, :start]` | Conflict detection started |
| `[:ex_maude, :iot, :detect_conflicts, :stop]` | Conflict detection completed |

### Measurements

- `duration` - Time in native units (convert with `System.convert_time_unit/3`)
- `system_time` - Wall clock time when event started
- `rule_count` - Number of rules (IoT events)
- `conflict_count` - Conflicts detected (IoT events)

### Metadata

- `operation` - Command type (`:reduce`, `:rewrite`, `:search`, `:execute`, `:parse`)
- `module` - Maude module name
- `result` - `:ok` or `:error`

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
  fn _event, %{duration: d}, %{operation: op, result: r}, _ ->
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
    ├── ExMaude.Maude      Binary management and platform detection
    ├── ExMaude.Pool       Poolboy worker pool management
    ├── ExMaude.Server     High-level API delegating to backend
    ├── ExMaude.Parser     Output parsing utilities
    └── ExMaude.Telemetry  Telemetry events and helpers
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
| **Port** | Higher (~500μs/op) | Default, works everywhere, full isolation |
| **C-Node** | Lower (~100μs/op) | Production, high-throughput workloads |
| **NIF** | Lowest (future) | Hot paths after profiling |

**Recommendation:** Start with Port backend, switch to C-Node if benchmarks show communication overhead is a bottleneck.

### Running Benchmarks

See [Development](#development) section for benchmark commands.

---

## Interactive Notebooks

Explore ExMaude interactively with Livebook:

| Notebook | Description | Livebook |
|----------|-------------|----------|
| [Quick Start](notebooks/quickstart.livemd) | Basic usage and examples | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fquickstart.livemd) |
| [Advanced Usage](notebooks/advanced.livemd) | IoT, custom modules, pooling | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fadvanced.livemd) |
| [Term Rewriting](notebooks/rewriting.livemd) | Rewriting and search deep dive | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Frewriting.livemd) |
| [Benchmarks](notebooks/benchmarks.livemd) | Performance metrics | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fbenchmarks.livemd) |

---

## Documentation

- [HexDocs](https://hexdocs.pm/ex_maude) - Full API documentation
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
