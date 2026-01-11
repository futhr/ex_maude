# Configure ExUnit
#
# Integration tests are excluded by default unless Maude is available.
# Run `mix test --include integration` to run integration tests when Maude is installed.
#
# Network tests (downloading from GitHub) are always excluded by default.
# Run `mix test --include network` to run network-dependent tests.
#
# C-Node tests require the maude_bridge binary and distributed node.
# Run `mix test --include cnode_integration` to run C-Node tests.
#
# NIF tests require the Rustler NIF to be compiled.
# Run `mix test --include nif_integration` to run NIF tests.

# Use ExMaude.Binary for consistent Maude detection
# (checks config, bundled binaries, and system PATH)
maude_available = ExMaude.Binary.find() != nil

# Tags that are always excluded (require special setup)
always_excluded = [:network, :cnode, :cnode_integration, :nif, :nif_integration]

exclude_tags =
  if maude_available do
    # Maude is available, only exclude special tags
    always_excluded
  else
    # Maude not available, also exclude integration tests
    [:integration | always_excluded]
  end

ExUnit.start(exclude: exclude_tags)
