# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

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
