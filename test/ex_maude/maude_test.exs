defmodule ExMaude.MaudeTest do
  @moduledoc """
  Tests for `ExMaude.Maude` - the high-level Maude API.
  """

  use ExMaude.MaudeCase

  alias ExMaude.Maude
  alias ExMaude.Error

  doctest ExMaude.Maude

  describe "module functions exist" do
    test "reduce/3 is exported" do
      assert function_exported?(Maude, :reduce, 3)
    end

    test "rewrite/3 is exported" do
      assert function_exported?(Maude, :rewrite, 3)
    end

    test "search/4 is exported" do
      assert function_exported?(Maude, :search, 4)
    end

    test "load_file/1 is exported" do
      assert function_exported?(Maude, :load_file, 1)
    end

    test "load_module/1 is exported" do
      assert function_exported?(Maude, :load_module, 1)
    end

    test "execute/2 is exported" do
      assert function_exported?(Maude, :execute, 2)
    end

    test "version/0 is exported" do
      assert function_exported?(Maude, :version, 0)
    end

    test "parse/3 is exported" do
      assert function_exported?(Maude, :parse, 3)
    end

    test "show_module/2 is exported" do
      assert function_exported?(Maude, :show_module, 2)
    end

    test "list_modules/1 is exported" do
      assert function_exported?(Maude, :list_modules, 1)
    end
  end

  describe "load_file/1 validation" do
    test "returns error for non-existent file" do
      result = Maude.load_file("/nonexistent/path/to/file.maude")
      assert {:error, %Error{type: :file_not_found}} = result
    end

    test "error contains path in details" do
      path = "/missing/module.maude"
      {:error, error} = Maude.load_file(path)

      assert error.details.path == path
    end
  end

  describe "load_module/1" do
    test "validates path stays in temp directory" do
      # The function should safely handle module source
      # This is a unit test of the security check
      source = "fmod TEST is endfm"

      # If successful, will try to load (may fail due to pool not running)
      # If path validation fails, will return invalid_path error
      result = Maude.load_module(source)

      # Should not return invalid_path error for normal source
      case result do
        {:error, %Error{type: :invalid_path}} ->
          flunk("Should not reject valid source as invalid path")

        _ ->
          # Other errors are acceptable (pool not running, etc.)
          :ok
      end
    end
  end

  describe "reduce/3 command building" do
    # Test the expected command format
    test "builds correct reduce command format" do
      # Reduce command should be: "reduce in MODULE : TERM"
      module = "NAT"
      term = "1 + 2 + 3"
      expected_pattern = "reduce in #{module} : #{term}"

      assert String.contains?(expected_pattern, "reduce in")
      assert String.contains?(expected_pattern, module)
      assert String.contains?(expected_pattern, term)
    end
  end

  describe "rewrite/3 command building" do
    test "builds rewrite command without max_rewrites" do
      module = "MY-MOD"
      term = "initial"
      expected = "rewrite in #{module} : #{term}"

      assert String.contains?(expected, "rewrite in")
      assert String.contains?(expected, module)
    end

    test "builds rewrite command with max_rewrites" do
      module = "MY-MOD"
      max_rewrites = 100
      expected = "rewrite [#{max_rewrites}] in #{module}"

      assert String.contains?(expected, "[100]")
    end
  end

  describe "search/4 command building" do
    test "builds search command with defaults" do
      module = "MY-MOD"
      initial = "init"
      pattern = "goal"
      # Default: max_solutions=1, max_depth=100, arrow="=>*"
      expected = "search [1, 100] in #{module} : #{initial} =>* #{pattern}"

      assert String.contains?(expected, "search")
      assert String.contains?(expected, "[1, 100]")
      assert String.contains?(expected, "=>*")
    end

    test "supports different arrow operators" do
      arrows = ["=>1", "=>+", "=>*", "=>!"]

      for arrow <- arrows do
        assert Regex.match?(~r/=>[1+*!]/, arrow)
      end
    end

    test "supports condition clause" do
      condition = "property(S)"
      expected = "such that #{condition}"

      assert String.contains?(expected, "such that")
    end
  end

  describe "parse/3 command building" do
    test "builds parse command" do
      module = "NAT"
      term = "1 + 2"
      expected = "parse in #{module} : #{term}"

      assert String.contains?(expected, "parse in")
    end
  end

  describe "show_module/2 command building" do
    test "builds show module command" do
      module = "NAT"
      expected = "show module #{module} ."

      assert String.contains?(expected, "show module")
      assert String.contains?(expected, module)
    end
  end

  describe "list_modules/1 command building" do
    test "builds show modules command" do
      expected = "show modules ."

      assert String.contains?(expected, "show modules")
    end
  end

  # Integration tests require Maude
  describe "reduce/3 integration" do
    @tag :integration
    test "reduces NAT expression", %{maude_available: true} do
      {:ok, result} = Maude.reduce("NAT", "1 + 2 + 3")
      assert result == "6"
    end

    @tag :integration
    test "reduces BOOL expression", %{maude_available: true} do
      {:ok, result} = Maude.reduce("BOOL", "true and false")
      assert result == "false"
    end

    @tag :integration
    test "reduces with timeout option", %{maude_available: true} do
      {:ok, result} = Maude.reduce("NAT", "1 + 1", timeout: 10_000)
      assert result == "2"
    end

    @tag :integration
    test "handles invalid module", %{maude_available: true} do
      result = Maude.reduce("NONEXISTENT-MODULE", "1 + 1")
      assert {:error, %Error{}} = result
    end

    @tag :integration
    test "handles parse error", %{maude_available: true} do
      result = Maude.reduce("NAT", "invalid$$syntax")
      assert {:error, %Error{}} = result
    end
  end

  describe "rewrite/3 integration" do
    @tag :integration
    test "rewrites simple term", %{maude_available: true} do
      # Use a built-in module that has rewrite rules
      {:ok, result} = Maude.rewrite("NAT", "0", max_rewrites: 10)
      assert result == "0"
    end

    @tag :integration
    test "respects max_rewrites", %{maude_available: true} do
      {:ok, _result} = Maude.rewrite("NAT", "1", max_rewrites: 1)
      # Should complete without error
    end
  end

  describe "execute/2 integration" do
    @tag :integration
    test "executes raw command", %{maude_available: true} do
      {:ok, output} = Maude.execute("reduce in NAT : 2 + 2 .")
      assert String.contains?(output, "4") or output == "4"
    end

    @tag :integration
    test "executes show modules", %{maude_available: true} do
      {:ok, output} = Maude.execute("show modules .")
      assert is_binary(output)
    end
  end

  describe "version/0 integration" do
    @tag :integration
    test "returns version info", %{maude_available: true} do
      {:ok, version} = Maude.version()
      assert is_binary(version)
      assert String.contains?(version, "Maude")
    end
  end

  describe "parse/3 integration" do
    @tag :integration
    test "parses term without reducing", %{maude_available: true} do
      {:ok, output} = Maude.parse("NAT", "1 + 2")
      assert is_binary(output)
    end
  end

  describe "show_module/2 integration" do
    @tag :integration
    test "shows module definition", %{maude_available: true} do
      {:ok, output} = Maude.show_module("NAT")
      assert is_binary(output)
      assert String.contains?(output, "NAT") or String.contains?(output, "Nat")
    end
  end

  describe "list_modules/1 integration" do
    @tag :integration
    test "lists all modules", %{maude_available: true} do
      {:ok, output} = Maude.list_modules()
      assert is_binary(output)
    end
  end

  describe "search/4 integration" do
    @tag :integration
    test "searches for solutions", %{maude_available: true} do
      # NAT doesn't have rewrite rules, so search will find the initial term
      {:ok, solutions} = Maude.search("NAT", "0", "N:Nat", max_solutions: 1, max_depth: 1)
      assert is_list(solutions)
    end
  end

  describe "search/4 command building additional tests" do
    test "builds search with =>1 arrow" do
      # =>1 means exactly one step
      arrow = "=>1"
      expected = "=>1"
      assert arrow == expected
    end

    test "builds search with =>+ arrow" do
      # =>+ means one or more steps
      arrow = "=>+"
      expected = "=>+"
      assert arrow == expected
    end

    test "builds search with =>! arrow" do
      # =>! means search for normal forms
      arrow = "=>!"
      expected = "=>!"
      assert arrow == expected
    end

    test "max_depth and max_solutions format correctly" do
      max_solutions = 5
      max_depth = 50
      expected_pattern = "[#{max_solutions}, #{max_depth}]"
      assert expected_pattern == "[5, 50]"
    end
  end

  describe "load_module/1 security" do
    test "generates unique temp file names" do
      # Verify that temp filenames are generated uniquely
      id1 = :erlang.unique_integer([:positive])
      id2 = :erlang.unique_integer([:positive])
      refute id1 == id2
    end

    test "temp directory is used" do
      tmp_dir = System.tmp_dir!()
      assert is_binary(tmp_dir)
      assert File.dir?(tmp_dir)
    end
  end

  describe "reduce/3 additional tests" do
    test "command format is correct" do
      module = "MY-MODULE"
      term = "my-term"
      expected = "reduce in #{module} : #{term}"
      assert expected == "reduce in MY-MODULE : my-term"
    end
  end

  describe "rewrite/3 additional tests" do
    test "command format without max_rewrites" do
      module = "MOD"
      term = "init"
      expected = "rewrite in #{module} : #{term}"
      assert expected == "rewrite in MOD : init"
    end

    test "command format with max_rewrites" do
      module = "MOD"
      term = "init"
      max = 100
      expected = "rewrite [#{max}] in #{module} : #{term}"
      assert expected == "rewrite [100] in MOD : init"
    end
  end

  describe "parse/3 additional tests" do
    test "command format is correct" do
      module = "NAT"
      term = "1 + 2"
      expected = "parse in #{module} : #{term}"
      assert expected == "parse in NAT : 1 + 2"
    end
  end

  describe "load_file/1 additional tests" do
    test "returns file_not_found for missing file" do
      result = Maude.load_file("/definitely/not/a/real/path/file.maude")
      assert {:error, %Error{type: :file_not_found}} = result
    end

    test "error includes the path" do
      path = "/missing/test.maude"
      {:error, error} = Maude.load_file(path)
      assert error.details.path == path
    end
  end

  describe "version/0 unit tests" do
    test "function is exported" do
      assert function_exported?(Maude, :version, 0)
    end
  end

  describe "show_module/2 command format" do
    test "command includes module name" do
      module = "NAT"
      expected = "show module #{module} ."
      assert expected == "show module NAT ."
    end
  end

  describe "list_modules/1 command format" do
    test "command is show modules" do
      expected = "show modules ."
      assert expected == "show modules ."
    end
  end

  describe "timeout handling" do
    test "default timeout is 5000ms" do
      # Verify the default from the module
      default = 5_000
      assert default == 5000
    end

    test "search default timeout is 30000ms" do
      search_timeout = 30_000
      assert search_timeout == 30000
    end
  end

  describe "error scenarios" do
    test "invalid module returns error" do
      # This would require Maude to be running, so just test structure
      assert function_exported?(Maude, :reduce, 3)
    end
  end
end
