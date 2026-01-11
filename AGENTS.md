# AGENTS.md

Guidance for AI agents working with ExMaude.

For detailed usage patterns and API guidelines, see [usage-rules.md](usage-rules.md).

## Project Overview

ExMaude is an Elixir library providing bindings to [Maude](https://maude.cs.illinois.edu/) formal verification system. It features a pluggable backend architecture with Poolboy worker pool management.

## Architecture

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

### Backend Comparison

| Backend | Isolation | Latency | Status | Use Case |
|---------|-----------|---------|--------|----------|
| **Port** | Full | Higher | Stable | Default, safe, works everywhere |
| **C-Node** | Full | Medium | Beta | Production, structured data |
| **NIF** | None | Lowest | Stub | Phase 3, hot paths after profiling |

### Module Overview

```
ExMaude (Main API)
    │
    ├── ExMaude.Backend         Backend behaviour and selection
    │   ├── Backend.Port        PTY-based Port communication
    │   ├── Backend.CNode       Erlang C-Node bridge
    │   └── Backend.NIF         Native integration (stub)
    │
    ├── ExMaude.Binary          Maude binary management & platform detection
    ├── ExMaude.Maude           High-level operations (reduce, rewrite, search)
    ├── ExMaude.Pool            Poolboy worker pool management
    ├── ExMaude.Server          Delegates to Backend.impl()
    ├── ExMaude.Parser          Output parsing utilities
    ├── ExMaude.Telemetry       Telemetry events and helpers
    │
    ├── ExMaude.IoT             IoT rule conflict detection API
    │   ├── IoT.Encoder         Rule-to-Maude encoding
    │   ├── IoT.Validator       Rule validation
    │   └── IoT.ConflictParser  Conflict output parsing
    │
    ├── ExMaude.Term            Structured term representation
    ├── ExMaude.Error           Structured error types
    └── ExMaude.Result.*        Result types (Reduction, Search, Solution)
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/ex_maude.ex` | Main API module, delegates to Maude |
| `lib/ex_maude/backend.ex` | Backend behaviour definition and selection |
| `lib/ex_maude/backend/port.ex` | Port-based backend implementation |
| `lib/ex_maude/backend/cnode.ex` | C-Node backend implementation |
| `lib/ex_maude/backend/nif.ex` | NIF backend stub (Phase 3) |
| `lib/ex_maude/binary.ex` | Maude binary management and platform detection |
| `lib/ex_maude/maude.ex` | High-level Maude operations |
| `lib/ex_maude/server.ex` | Server delegating to configured backend |
| `lib/ex_maude/pool.ex` | Poolboy worker pool |
| `lib/ex_maude/parser.ex` | Output parsing |
| `lib/ex_maude/telemetry.ex` | Telemetry events and span helper |
| `lib/ex_maude/iot.ex` | IoT conflict detection API |
| `lib/ex_maude/iot/encoder.ex` | Rule encoding to Maude syntax |
| `lib/ex_maude/iot/validator.ex` | Rule validation with depth limits |
| `lib/ex_maude/iot/conflict_parser.ex` | Conflict output parsing |
| `lib/ex_maude/term.ex` | Structured term type |
| `lib/ex_maude/error.ex` | Structured error types |
| `lib/ex_maude/result/reduction.ex` | Reduction result type |
| `lib/ex_maude/result/search.ex` | Search result type |
| `lib/ex_maude/result/solution.ex` | Solution type |
| `c_src/maude_bridge.c` | C-Node bridge source code |
| `c_src/Makefile` | C-Node compilation |
| `priv/maude/bin/` | Bundled Maude binaries |
| `priv/maude/iot-rules.maude` | IoT conflict detection Maude module |

## Development Commands

```bash
mix setup                       # Install deps
mix test                        # Run tests (unit only)
mix test --include integration  # Run with Maude
mix test --include network      # Run GitHub API tests
mix lint                        # Format + Credo + Dialyzer
mix check                       # All quality checks
mix sobelow                     # Security analysis
mix docs                        # Generate docs
mix maude.install               # Install Maude binary
mix maude.install --check       # Check Maude availability
mix coveralls                   # Test coverage report
mix bench                       # Run main benchmarks
mix bench.backends              # Run backend comparison benchmarks
```

## C-Node Compilation

The C-Node backend requires compilation:

```bash
cd c_src && make      # Compile maude_bridge binary
cd c_src && make clean  # Clean build artifacts
```

Or automatically via `elixir_make` during `mix compile`.

## Testing

- **Unit tests** - Run without Maude, test parsing/validation logic
- **Integration tests** - Tagged `@tag :integration`, require Maude binary
- **Network tests** - Tagged `@tag :network`, make GitHub API calls
- Use `ExMaude.MaudeCase` for integration test setup

Test structure:
```
test/
├── ex_maude/
│   ├── maude_test.exs        # Maude module tests
│   ├── pool_test.exs         # Pool tests
│   ├── server_test.exs       # Server tests
│   ├── parser_test.exs       # Parser unit tests
│   ├── telemetry_test.exs    # Telemetry event tests
│   ├── iot_test.exs          # IoT module tests
│   ├── error_test.exs        # Error type tests
│   ├── term_test.exs         # Term type tests
│   └── integration_test.exs  # Full integration tests
├── mix/tasks/                 # Mix task tests
└── support/
    └── maude_case.ex         # Shared integration test setup
```

## Telemetry Events

ExMaude emits standard telemetry events:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:ex_maude, :command, :start]` | `system_time` | `operation`, `module` |
| `[:ex_maude, :command, :stop]` | `duration` | `operation`, `module`, `result` |
| `[:ex_maude, :command, :exception]` | `duration` | `operation`, `module`, `kind`, `reason` |
| `[:ex_maude, :pool, :checkout, :start]` | `system_time` | - |
| `[:ex_maude, :pool, :checkout, :stop]` | `duration` | `result` |
| `[:ex_maude, :iot, :detect_conflicts, :start]` | `system_time`, `rule_count` | - |
| `[:ex_maude, :iot, :detect_conflicts, :stop]` | `duration`, `conflict_count` | `result` |

See `ExMaude.Telemetry.events/0` for programmatic access.

## Error Handling

All errors use `ExMaude.Error` struct with standardized types:

| Type | Description |
|------|-------------|
| `:timeout` | Operation timed out |
| `:parse_error` | Maude syntax/parse error |
| `:module_error` | Module not found/load error |
| `:execution_error` | Maude execution error |
| `:crash` | Process crashed |
| `:file_not_found` | File does not exist |
| `:partial_load` | Some workers failed to load |
| `:pool_error` | Pool checkout failed |
| `:invalid_path` | Path validation failed |
| `:validation` | Rule validation failed |

## Configuration

```elixir
config :ex_maude,
  backend: :port,                      # :port | :cnode | :nif
  maude_path: nil,                     # nil = auto-detect bundled binary
  pool_size: 4,                        # Worker processes
  pool_max_overflow: 2,                # Extra workers under load
  timeout: 5_000,                      # Default command timeout
  start_pool: false,                   # Auto-start on app start
  use_pty: true                        # Use PTY wrapper (Port backend)
```

### Backend Selection

```elixir
# Check available backends
ExMaude.Backend.available_backends()
#=> [:port] or [:port, :cnode]

# Get current backend module
ExMaude.Backend.impl()
#=> ExMaude.Backend.Port
```

## Common Patterns

### Running Maude Commands

```elixir
# High-level API (preferred)
{:ok, result} = ExMaude.reduce("NAT", "1 + 2")
{:ok, solutions} = ExMaude.search("MOD", "init", "goal")

# Low-level with pool
ExMaude.Pool.transaction(fn worker ->
  ExMaude.Server.execute(worker, "reduce in NAT : 1 + 2 .")
end)
```

### Loading Modules

```elixir
# From file (broadcasts to all workers)
:ok = ExMaude.load_file("/path/to/module.maude")

# From string
:ok = ExMaude.load_module("fmod TEST is ... endfm")

# IoT rules module
:ok = ExMaude.load_file(ExMaude.iot_rules_path())
```

### IoT Conflict Detection

```elixir
rules = [
  %{id: "r1", thing_id: "light", trigger: {:prop_eq, "motion", true},
    actions: [{:set_prop, "light", "state", "on"}], priority: 1},
  %{id: "r2", thing_id: "light", trigger: {:prop_gt, "time", 2300},
    actions: [{:set_prop, "light", "state", "off"}], priority: 1}
]

{:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
```

## References

- [usage-rules.md](usage-rules.md) - Detailed usage patterns
- [README.md](README.md) - Quick start guide
- [Maude System](https://maude.cs.illinois.edu/)
- [Maude Manual](https://maude.lcc.uma.es/maude-manual/)
- [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - IoT conflict detection
