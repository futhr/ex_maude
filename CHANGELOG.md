# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Pluggable backend architecture** with three communication backends:
  - `ExMaude.Backend.Port` - Default, PTY-based communication (safe, works everywhere)
  - `ExMaude.Backend.CNode` - Erlang C-Node with binary protocol (lower latency)
  - `ExMaude.Backend.NIF` - Native integration stub (Phase 3, not yet implemented)
- `ExMaude.Backend` behaviour defining unified interface for all backends
- `ExMaude.Binary` module for Maude binary management and platform detection
- Bundled Maude binaries for common platforms (darwin-arm64, darwin-x64, linux-x64)
- Git LFS configuration for binary storage (`.gitattributes`)
- C-Node bridge source code (`c_src/maude_bridge.c`) and Makefile
- `elixir_make` dependency for native code compilation
- Backend comparison benchmarks (`bench/backends_bench.exs`)
- `mix maude.install --check` option to diagnose Maude availability
- Comprehensive test suites for all backend modules

### Changed

- `ExMaude.Server` now delegates to `ExMaude.Backend.impl()` for backend selection
- `ExMaude.Pool` uses configured backend module for worker processes
- `mix maude.install` updated to show bundled binary is now the default
- Configuration now supports `backend: :port | :cnode | :nif` option

## [0.1.0] - 2026-01-11

### Added

- Initial release
- Port-based GenServer for Maude process communication
- Poolboy worker pool for concurrent operations
- High-level API: `reduce/3`, `rewrite/3`, `search/4`
- Module loading: `load_file/1`, `load_module/1`
- Output parsing utilities for results, search solutions, errors
- Mix task `mix maude.install` for Maude binary installation
- IoT rule conflict detection Maude module based on AutoIoT paper
- Comprehensive documentation and typespecs
- Telemetry events for observability
- GitHub Actions CI/CD workflows
- ex_check integration with credo, dialyzer, doctor, sobelow

[Unreleased]: https://github.com/futhr/ex_maude/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/futhr/ex_maude/releases/tag/v0.1.0
