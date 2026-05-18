# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [v0.2.0](https://github.com/futhr/ex_maude/compare/v0.1.1...v0.2.0) (2026-05-18)

### Features:

* add `ai-rules.maude` template (`priv/maude/ai-rules.maude`) — second
  bundled Maude module alongside `iot-rules.maude`. Targets AI-generated
  automation rules over Agents, Capabilities, ToolInvocations, and richer
  predicates (capability, budget, jurisdiction, authority). Detects ten
  conflict types including tool-call conflict, capability shadowing,
  pack-tool composition mismatch, sovereignty violation, authority
  escalation, approval-gate bypass, and agent-loop cascade. ~570 lines
  of algebraic specification.

* add `ExMaude.AI` Elixir API parallel to `ExMaude.IoT`. Submodules:

    - `ExMaude.AI.Encoder` — Elixir term → Maude syntax for ai-rules
    - `ExMaude.AI.Validator` — pre-encode rule validation, including
      explicit `:unverifiable` returns for `:contains` / `:matches`
      regex operators
    - `ExMaude.AI.ConflictParser` — Maude output → typed conflict maps,
      handling both pairwise (`aiConflict`) and single-rule
      (`aiConflictSingle`) constructors

* add `ExMaude.ai_rules_path/0` helper returning the bundled
  `ai-rules.maude` path under `priv/`.

* add `[:ex_maude, :ai, :detect_conflicts, :start | :stop]` telemetry
  events with `template: :ai_rules` metadata for observability parity
  with the IoT path.

* promote `:nif` backend to production grade. The Rust crate now uses a
  dedicated reader thread feeding a `crossbeam-channel`, enforces per-command
  timeouts via `recv_timeout`, captures both stdout and stderr (matching the
  Port backend's `stderr_to_stdout` semantics), and returns structured
  errors (`{:timeout, ms}`, `:eof`, `{:io_error, msg}`, `{:lock_poisoned, what}`).
  All blocking entry points run on the `DirtyIo` scheduler.

* add `ExMaude.Parser.parse_backend_response/1` as the single source of truth
  for turning a Maude command's raw output into `{:ok, value} | {:error, %Error{}}`.
  Both the Port and NIF backends now share this parser.

* expose a `nif_loaded/0` probe in the NIF native module — a cheap call used
  by `ExMaude.Backend.available?/1` to detect whether Rustler has populated
  the native function table.

### Bug Fixes:

* fix `ExMaude.Backend.available?(:nif)` checking the wrong function name
  (`:initialize/1` instead of the actual `:start/1`), which made the backend
  appear unavailable even when the precompiled binary loaded correctly.

* fix `ExMaude.Backend.NIF` no longer falling back into a "stub mode" when
  the NIF fails to load — the GenServer now refuses to start and surfaces
  a clear `:nif_not_loaded` error pointing at the `EX_MAUDE_BUILD=1`
  escape hatch.

* fix `:not_implemented` error type removed; replaced by `:nif_not_loaded`
  and `:nif_error` for genuine NIF failure modes.

## [v0.1.1](https://github.com/futhr/ex_maude/compare/v0.1.0...v0.1.1) (2026-04-07)

### Bug Fixes:

* align NIF precompiled build config with production patterns by Tobias Bohwalli

* switch NIF to RustlerPrecompiled for proper Hex packaging by Tobias Bohwalli

## [v0.1.0](https://github.com/futhr/ex_maude/compare/v0.1.0...v0.1.0) (2026-04-03)

### Features:

* add Livebook notebooks for interactive documentation by Tobias Bohwalli

* add bundled Maude binaries and IoT rules module by Tobias Bohwalli

* add NIF backend stub with Rustler scaffolding by Tobias Bohwalli

* add C-Node backend with maude_bridge by Tobias Bohwalli

* add mix maude.install task for binary installation by Tobias Bohwalli

* add IoT rule conflict detection module by Tobias Bohwalli

* add Maude binary management, server, pool, and public API by Tobias Bohwalli

* add backend behaviour and Port backend implementation by Tobias Bohwalli

* add parser and telemetry modules by Tobias Bohwalli

* add core types (Error, Term, Result structs) by Tobias Bohwalli

### Bug Fixes:

* remove HTML div wrapper and pre-release notice for hex.pm rendering by Tobias Bohwalli

* suppress noisy make output when binary is up-to-date by Tobias Bohwalli

* handle missing Location header in redirect safely by Tobias Bohwalli

* tighten encoder specs to resolve dialyzer contract_supertype warning by Tobias Bohwalli

* make CNode backend fully functional by Tobias Bohwalli

* split telemetry tests to use MaudeCase for integration tests by Tobias Bohwalli

* handle write() return values in maude_bridge.c by Tobias Bohwalli

* add ex_doc and doctor to test env for CI by Tobias Bohwalli

* suppress unused alias warnings in conditional test blocks by Tobias Bohwalli

* replace deprecated Exception.exception?/1 with is_exception/1 by Tobias Bohwalli

* convert @platform_patterns to function for compile-time compatibility by Tobias Bohwalli

### Performance Improvements:

* add benchmark suite by Tobias Bohwalli
