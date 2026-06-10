# Configure ExUnit
#
# Integration tests are excluded by default unless Maude is available.
# Run `mix test --include integration` to run integration tests when Maude is installed.
#
# Network tests (downloading from GitHub) are always excluded by default.
# Run `mix test --include network` to run network-dependent tests.
#
# C-Node tests require the maude_bridge binary and distributed node.
# Run `mix test --include cnode --include integration` to run C-Node tests.
#
# NIF tests require the Rustler NIF to be compiled.
# Run `mix test --include nif --include integration` to run NIF tests.

# function_exported?/3 does not load modules, ExUnit randomizes test order,
# and whether `mix test` happens to preload task modules varies across
# Elixir versions — eagerly load every application module so the
# module-contract tests (`assert function_exported?(...)`) cannot flake on
# first-touch ordering.
{:ok, modules} = :application.get_key(:ex_maude, :modules)
Enum.each(modules, &Code.ensure_loaded!/1)

# Use ExMaude.Binary for consistent Maude detection
# (checks config, bundled binaries, and system PATH)
maude_available = ExMaude.Binary.find() != nil

# Tags that are always excluded (require special setup).
# Compose with `:integration` for tests that also need a live Maude
# process — e.g. `mix test --include cnode --include integration`.
always_excluded = [:network, :cnode, :nif]

exclude_tags =
  if maude_available do
    # Maude is available, only exclude special tags
    always_excluded
  else
    # Maude not available, also exclude integration tests
    [:integration | always_excluded]
  end

ExUnit.start(exclude: exclude_tags)
