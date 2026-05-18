defmodule ExMaudeTest do
  @moduledoc false

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
