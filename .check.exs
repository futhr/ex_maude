[
  parallel: true,
  # Show skipped tools in the summary — a silently skipped tool looks like a
  # passing gate. (deps: [:compiler] entries used to be skipped this way:
  # ex_check runs the compiler separately before the pipeline, so it never
  # appears in the finished set that dependency resolution consults. Never
  # name :compiler in deps.)
  skipped: true,

  tools: [
    # Dependencies
    {:deps_get, command: "mix deps.get"},

    # Elixir compilation — ex_check always runs this first and gates the
    # rest of the pipeline on it.
    {:compiler, command: "mix compile --warnings-as-errors"},

    # C-Node compilation (only if c_src exists)
    {:c_compile, command: "make -C c_src", enabled: File.dir?("c_src")},

    # Formatting
    {:formatter, command: "mix format --check-formatted"},

    # C code format check (optional, only if clang-format installed)
    {:c_format_check,
     command: "make -C c_src format-check",
     enabled: File.dir?("c_src") and System.find_executable("clang-format") != nil},

    # Rust format check (only if native Rust code exists and cargo installed)
    {:rust_fmt,
     command: "cargo fmt --check",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif") and System.find_executable("cargo") != nil},

    # Static analysis
    {:credo, command: "mix credo --strict"},
    {:sobelow, command: "mix sobelow --config"},

    # C code linting with clang-tidy (optional, only if installed)
    {:c_lint,
     command: "make -C c_src lint",
     enabled: File.dir?("c_src") and System.find_executable("clang-tidy") != nil,
     deps: [:c_compile]},

    # Rust clippy linting (only if native Rust code exists and cargo installed)
    {:rust_clippy,
     command: "cargo clippy --lib -- -D warnings",
     cd: "native/ex_maude_nif",
     enabled: File.dir?("native/ex_maude_nif") and System.find_executable("cargo") != nil},

    # Security and dependencies
    {:mix_audit, command: "mix deps.audit"},

    # Type checking
    {:dialyzer, command: "mix dialyzer"},

    # Documentation
    {:doctor, command: "mix doctor"},
    {:ex_doc, command: "mix docs"},

    # Tests
    {:ex_unit, command: "mix test --cover"},

    # C-Node integration tests (only if binary exists)
    {:test_cnode,
     command: "mix test --include cnode --include integration",
     enabled: File.exists?("priv/maude_bridge"),
     deps: [:c_compile, :ex_unit]},

    # NIF integration tests (only if NIF is compiled)
    {:test_nif,
     command: "mix test --include nif --include integration",
     enabled:
       File.exists?("priv/native/libex_maude_nif.so") or
         File.exists?("priv/native/libex_maude_nif.dylib"),
     deps: [:ex_unit]}
  ]
]
