defmodule ExMaudeTest do
  @moduledoc """
  Tests for the main `ExMaude` module.

  This test module verifies:

    * All core modules are properly loaded and accessible
    * The `iot_rules_path/0` helper returns valid paths
    * All delegated functions are correctly exported with proper arities

  These tests run without requiring Maude to be installed, making them
  suitable for CI environments and quick validation of the module structure.

  ## Test Categories

    * `module loading` - Ensures all ExMaude modules compile and load
    * `iot_rules_path/0` - Validates the bundled Maude module path helper
    * `delegated functions` - Confirms the public API is properly delegated

  ## Running Tests

      # Run all tests in this file
      mix test test/ex_maude_test.exs

      # Run with verbose output
      mix test test/ex_maude_test.exs --trace
  """

  use ExUnit.Case

  doctest ExMaude

  describe "module loading" do
    test "ExMaude module exists" do
      assert Code.ensure_loaded?(ExMaude)
    end

    test "ExMaude.Maude module exists" do
      assert Code.ensure_loaded?(ExMaude.Maude)
    end

    test "ExMaude.Pool module exists" do
      assert Code.ensure_loaded?(ExMaude.Pool)
    end

    test "ExMaude.Server module exists" do
      assert Code.ensure_loaded?(ExMaude.Server)
    end

    test "ExMaude.Parser module exists" do
      assert Code.ensure_loaded?(ExMaude.Parser)
    end
  end

  describe "iot_rules_path/0" do
    test "returns path to iot-rules.maude" do
      path = ExMaude.iot_rules_path()
      assert is_binary(path)
      assert String.ends_with?(path, "iot-rules.maude")
    end

    test "path contains priv directory" do
      path = ExMaude.iot_rules_path()
      assert String.contains?(path, "priv")
    end
  end

  # Delegated functions - test that they exist
  describe "delegated functions" do
    test "reduce/3 is defined" do
      assert function_exported?(ExMaude, :reduce, 3)
    end

    test "rewrite/3 is defined" do
      assert function_exported?(ExMaude, :rewrite, 3)
    end

    test "search/4 is defined" do
      assert function_exported?(ExMaude, :search, 4)
    end

    test "load_file/1 is defined" do
      assert function_exported?(ExMaude, :load_file, 1)
    end

    test "load_module/1 is defined" do
      assert function_exported?(ExMaude, :load_module, 1)
    end

    test "execute/2 is defined" do
      assert function_exported?(ExMaude, :execute, 2)
    end

    test "version/0 is defined" do
      assert function_exported?(ExMaude, :version, 0)
    end
  end
end
