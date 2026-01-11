[
  parallel: true,
  skipped: false,

  tools: [
    # Dependencies
    {:deps_get,
     command: "mix deps.get",
     order: 0},

    # Elixir compilation
    {:compiler,
     command: "mix compile --warnings-as-errors",
     order: 1,
     deps: [:deps_get]},

    # C-Node compilation (only if c_src exists)
    {:c_compile,
     command: "make -C c_src",
     enabled: File.dir?("c_src"),
     order: 2,
     deps: [:compiler]},

    # Formatting
    {:formatter,
     command: "mix format --check-formatted",
     order: 3},

    # C code format check (optional, only if clang-format installed)
    {:c_format_check,
     command: "make -C c_src format-check",
     enabled: File.dir?("c_src") and System.find_executable("clang-format") != nil,
     order: 3},

    # Rust format check (only if native Rust code exists and cargo installed)
    {:rust_fmt,
     command: "cargo fmt --check",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif") and System.find_executable("cargo") != nil,
     order: 3},

    # Static analysis
    {:credo,
     command: "mix credo --strict",
     order: 4,
     deps: [:compiler]},

    {:sobelow,
     command: "mix sobelow --config",
     order: 4,
     deps: [:compiler]},

    # C code linting with clang-tidy (optional, only if installed)
    {:c_lint,
     command: "make -C c_src lint",
     enabled: File.dir?("c_src") and System.find_executable("clang-tidy") != nil,
     order: 4,
     deps: [:c_compile]},

    # Rust clippy linting (only if native Rust code exists and cargo installed)
    {:rust_clippy,
     command: "cargo clippy --lib -- -D warnings",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif") and System.find_executable("cargo") != nil,
     order: 4},

    # Security and dependencies
    {:mix_audit,
     command: "mix deps.audit",
     order: 5,
     deps: [:deps_get]},

    # Type checking (runs after compilation)
    {:dialyzer,
     command: "mix dialyzer",
     order: 6,
     deps: [:compiler]},

    # Documentation
    {:doctor,
     command: "mix doctor",
     order: 7,
     deps: [:compiler]},

    {:ex_doc,
     command: "mix docs",
     order: 7,
     deps: [:compiler]},

    # Tests - run all test suites
    {:ex_unit,
     command: "mix test --cover",
     order: 8,
     deps: [:compiler]},

    # C-Node integration tests (only if binary exists)
    {:test_cnode,
     command: "mix test --include cnode_integration",
     enabled: File.exists?("priv/maude_bridge"),
     order: 9,
     deps: [:c_compile, :ex_unit]},

    # NIF integration tests (only if NIF is compiled)
    {:test_nif,
     command: "mix test --include nif_integration",
     enabled: File.exists?("priv/native/libex_maude_nif.so") or
              File.exists?("priv/native/libex_maude_nif.dylib"),
     order: 9,
     deps: [:compiler, :ex_unit]}
  ]
]
