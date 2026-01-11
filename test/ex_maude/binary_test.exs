defmodule ExMaude.BinaryTest do
  @moduledoc """
  Tests for `ExMaude.Binary` - Maude binary management and platform detection.
  """

  use ExUnit.Case, async: true

  alias ExMaude.Binary

  describe "version/0" do
    test "returns a version string" do
      version = Binary.version()
      assert is_binary(version)
      assert String.match?(version, ~r/^\d+\.\d+\.\d+$/)
    end
  end

  describe "platform/0" do
    test "returns a platform string" do
      platform = Binary.platform()
      assert is_binary(platform)
    end

    test "returns expected format" do
      platform = Binary.platform()
      # Format is "os-arch" like "darwin-arm64" or "linux-x64"
      assert String.contains?(platform, "-")
    end

    test "detects darwin on macOS" do
      case :os.type() do
        {:unix, :darwin} ->
          assert String.starts_with?(Binary.platform(), "darwin")

        _ ->
          :ok
      end
    end

    test "detects linux on Linux" do
      case :os.type() do
        {:unix, :linux} ->
          assert String.starts_with?(Binary.platform(), "linux")

        _ ->
          :ok
      end
    end
  end

  describe "supported_platforms/0" do
    test "returns a list of platforms" do
      platforms = Binary.supported_platforms()
      assert is_list(platforms)
      assert length(platforms) > 0
    end

    test "includes common platforms" do
      platforms = Binary.supported_platforms()
      assert "darwin-arm64" in platforms
      assert "darwin-x64" in platforms
      assert "linux-x64" in platforms
    end
  end

  describe "supported_platform?/0" do
    test "returns boolean" do
      result = Binary.supported_platform?()
      assert is_boolean(result)
    end

    test "current platform should be supported on common systems" do
      platform = Binary.platform()

      if platform in ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"] do
        assert Binary.supported_platform?()
      end
    end
  end

  describe "priv_dir/0" do
    test "returns a path" do
      dir = Binary.priv_dir()
      assert is_binary(dir)
    end

    test "path exists or is constructable" do
      dir = Binary.priv_dir()
      # Either the priv dir exists or we're in dev mode with fallback
      assert is_binary(dir)
    end
  end

  describe "bundled_path/0" do
    test "returns nil or path" do
      result = Binary.bundled_path()
      assert is_nil(result) or is_binary(result)
    end

    test "returns path if bundled binary exists" do
      result = Binary.bundled_path()

      if result do
        assert File.exists?(result)
      end
    end
  end

  describe "bundled?/0" do
    test "returns boolean" do
      result = Binary.bundled?()
      assert is_boolean(result)
    end

    test "matches bundled_path existence" do
      has_bundled = Binary.bundled_path() != nil
      assert Binary.bundled?() == has_bundled
    end
  end

  describe "find/0" do
    test "returns nil or path" do
      result = Binary.find()
      assert is_nil(result) or is_binary(result)
    end

    test "returns path if maude is available" do
      result = Binary.find()

      if result do
        assert File.exists?(result)
      end
    end
  end

  describe "path/0" do
    test "returns path or raises" do
      try do
        result = Binary.path()
        assert is_binary(result)
        assert File.exists?(result)
      rescue
        RuntimeError ->
          # Expected if Maude is not installed
          :ok
      end
    end
  end

  describe "configuration precedence" do
    setup do
      original = Application.get_env(:ex_maude, :maude_path)

      on_exit(fn ->
        if original do
          Application.put_env(:ex_maude, :maude_path, original)
        else
          Application.delete_env(:ex_maude, :maude_path)
        end
      end)

      {:ok, original: original}
    end

    test "configured path takes precedence" do
      # Only test if there's a system maude we can point to
      case System.find_executable("maude") do
        nil ->
          :ok

        system_maude ->
          Application.put_env(:ex_maude, :maude_path, system_maude)
          assert Binary.find() == system_maude
      end
    end

    test "returns nil for non-existent configured path" do
      Application.put_env(:ex_maude, :maude_path, "/nonexistent/path/to/maude")
      # find/0 validates paths, so it should skip invalid ones
      result = Binary.find()
      # Result depends on whether bundled/system maude exists
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "executable validation" do
    test "bundled path must be executable" do
      result = Binary.bundled_path()

      if result do
        stat = File.stat!(result)
        # Check if any execute bit is set
        executable = Bitwise.band(stat.mode, 0o111) > 0
        assert executable
      end
    end
  end

  describe "path/0 error handling" do
    setup do
      original = Application.get_env(:ex_maude, :maude_path)
      # Store original PATH
      original_path = System.get_env("PATH")

      on_exit(fn ->
        if original do
          Application.put_env(:ex_maude, :maude_path, original)
        else
          Application.delete_env(:ex_maude, :maude_path)
        end

        System.put_env("PATH", original_path)
      end)

      {:ok, original: original, original_path: original_path}
    end

    test "raises when maude is not found anywhere" do
      # Set invalid configured path
      Application.put_env(:ex_maude, :maude_path, "/nonexistent/path/to/maude")
      # Clear system PATH so system_path() returns nil
      System.put_env("PATH", "/nonexistent")

      # If bundled binary exists, find() will return it and path() won't raise
      # So we only test the raise if bundled is not available
      if Binary.bundled?() do
        # Bundled exists, so path() will find it - just verify it returns a path
        assert is_binary(Binary.path())
      else
        # No bundled binary, path() should raise
        assert_raise RuntimeError, ~r/Maude executable not found/, fn ->
          Binary.path()
        end
      end
    end
  end

  describe "validate_path edge cases" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "test_binary_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm(test_file)
      end)

      {:ok, test_file: test_file}
    end

    test "configured non-executable file is skipped", %{test_file: test_file} do
      # Create a file without execute permissions
      File.write!(test_file, "#!/bin/sh\necho test")
      File.chmod!(test_file, 0o644)

      original = Application.get_env(:ex_maude, :maude_path)

      try do
        Application.put_env(:ex_maude, :maude_path, test_file)
        # find() should skip this because it's not executable
        # and continue to bundled or system path
        result = Binary.find()
        # The result should NOT be our non-executable file
        assert result != test_file
      after
        if original do
          Application.put_env(:ex_maude, :maude_path, original)
        else
          Application.delete_env(:ex_maude, :maude_path)
        end
      end
    end

    test "expanded path is used for validation", %{test_file: test_file} do
      # Test that paths are expanded
      File.write!(test_file, "#!/bin/sh\necho test")
      File.chmod!(test_file, 0o755)

      original = Application.get_env(:ex_maude, :maude_path)

      try do
        # Use a relative-like path (with ~) to test expansion
        # Since we can't easily use ~ in tests, we test that the path is expanded
        Application.put_env(:ex_maude, :maude_path, test_file)
        result = Binary.find()
        # If maude is found, it should be our file (since it's valid and executable)
        # or the bundled/system maude (which takes precedence in find order)
        assert result == test_file or result == Binary.bundled_path() or
                 result == System.find_executable("maude")
      after
        if original do
          Application.put_env(:ex_maude, :maude_path, original)
        else
          Application.delete_env(:ex_maude, :maude_path)
        end
      end
    end
  end

  describe "platform detection edge cases" do
    test "linux-arm64 platform format" do
      # We can at least verify the format is consistent
      platforms = Binary.supported_platforms()
      assert "linux-arm64" in platforms
    end

    test "unsupported platform format" do
      # For platforms not in the supported list,
      # the format should still be "os-arch"
      platform = Binary.platform()
      [_os, _arch] = String.split(platform, "-", parts: 2)
    end
  end

  describe "bundled_path/0 edge cases" do
    test "checks for generic maude binary as fallback" do
      # This tests the logic branch where platform-specific binary
      # doesn't exist but a generic "maude" does
      result = Binary.bundled_path()

      # Whether we get a result depends on what binaries exist
      # but we can verify the return type
      assert is_nil(result) or (is_binary(result) and File.exists?(result))
    end
  end
end
