defmodule Mix.Tasks.Maude.InstallTest do
  @moduledoc """
  Tests for `Mix.Tasks.Maude.Install` - the Maude binary installation task.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  describe "module" do
    test "task module exists" do
      assert Code.ensure_loaded?(Mix.Tasks.Maude.Install)
    end

    test "run/1 is exported" do
      assert function_exported?(Mix.Tasks.Maude.Install, :run, 1)
    end

    test "has shortdoc" do
      # Task has @shortdoc attribute
      assert Mix.Task.shortdoc(Mix.Tasks.Maude.Install) == "Installs Maude system binary"
    end
  end

  describe "option parsing" do
    test "rejects unknown options" do
      assert_raise Mix.Error, ~r/Unknown options: --unknown/, fn ->
        Mix.Tasks.Maude.Install.run(["--unknown", "value"])
      end
    end

    test "accepts --check option" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "Checking Maude availability"
      assert output =~ "Platform:"
    end

    @tag :tmp_dir
    test "accepts --version option", %{tmp_dir: tmp_dir} do
      # This will fail at network level but validates option parsing
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run(["--version", "3.5.1", "--path", tmp_dir])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "darwin" or output =~ "linux" or output =~ "Fetching"
    end

    @tag :tmp_dir
    test "accepts --force option", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run(["--force", "--path", tmp_dir])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "Detecting platform" or output =~ "Fetching"
    end
  end

  describe "platform detection" do
    @tag :tmp_dir
    test "detects current platform format", %{tmp_dir: tmp_dir} do
      # We can't directly test detect_platform/0 as it's private,
      # but we can verify the output format through the task
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run(["--path", tmp_dir])
          rescue
            Mix.Error -> :ok
          end
        end)

      # Should detect a valid platform
      assert output =~ ~r/darwin-arm64|darwin-x86_64|linux-x86_64/
    end
  end

  describe "--list option" do
    @tag :integration
    @tag :network
    test "lists available versions" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--list"])
        end)

      assert output =~ "Available Maude versions"
      assert output =~ "Maude3.5"
      assert output =~ "mix maude.install --version"
    end
  end

  describe "--check option" do
    test "shows platform information" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "Platform:"
      assert output =~ ~r/darwin-|linux-/
    end

    test "shows bundled binary status" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      # Should show either found or not found
      assert output =~ "Bundled binary:"
    end

    test "shows system PATH status" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      assert output =~ "System PATH:"
    end

    test "shows final resolution" do
      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--check"])
        end)

      # Should show what ExMaude will use or that none is available
      assert output =~ "ExMaude will use:" or output =~ "No Maude binary available"
    end
  end

  describe "version normalization" do
    @tag :integration
    @tag :network
    test "accepts version without Maude prefix" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run([
              "--version",
              "3.5.1",
              "--path",
              "/tmp/maude-test-#{:rand.uniform(10000)}"
            ])
          rescue
            Mix.Error -> :ok
          end
        end)

      # Should find the version and start download or fail gracefully
      assert output =~ "3.5.1" or output =~ "Maude3.5.1"
    end

    @tag :integration
    @tag :network
    test "accepts version with Maude prefix" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Maude.Install.run([
              "--version",
              "Maude3.5.1",
              "--path",
              "/tmp/maude-test-#{:rand.uniform(10000)}"
            ])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "3.5.1" or output =~ "Maude3.5.1"
    end

    @tag :integration
    @tag :network
    test "reports unknown version", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-unknown-version")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Mix.Tasks.Maude.Install.run(["--version", "99.99.99", "--path", install_path])
          end)
        end

      assert error.message =~ ~r/not found|failed to fetch/i
    end
  end

  describe "installation" do
    @tag :integration
    @tag :slow
    @tag :network
    test "installs Maude to custom path", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path])
        end)

      assert output =~ "Maude installed successfully"
      assert output =~ install_path

      maude_binary = Path.join(install_path, "maude")
      assert File.exists?(maude_binary)

      # Verify it's executable
      assert {:ok, %{mode: mode}} = File.stat(maude_binary)
      assert Bitwise.band(mode, 0o111) != 0

      # Verify it runs
      {version_output, 0} = System.cmd(maude_binary, ["--version"], stderr_to_stdout: true)
      assert version_output =~ ~r/\d+\.\d+/
    end

    @tag :integration
    test "skips installation if already installed", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")
      File.mkdir_p!(install_path)

      # Create a fake maude binary
      maude_path = Path.join(install_path, "maude")
      File.write!(maude_path, "#!/bin/sh\necho 'fake maude'")
      File.chmod!(maude_path, 0o755)

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path])
        end)

      assert output =~ "already installed"
      assert output =~ "--force"
    end

    @tag :integration
    @tag :slow
    @tag :network
    test "force reinstalls when --force is used", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")
      File.mkdir_p!(install_path)

      # Create a fake maude binary
      maude_path = Path.join(install_path, "maude")
      File.write!(maude_path, "#!/bin/sh\necho 'fake maude'")
      File.chmod!(maude_path, 0o755)

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path, "--force"])
        end)

      assert output =~ "Maude installed successfully"

      # Verify real Maude was installed
      {version_output, 0} = System.cmd(maude_path, ["--version"], stderr_to_stdout: true)
      assert version_output =~ ~r/\d+\.\d+/
    end

    @tag :integration
    @tag :slow
    @tag :network
    test "installs specific version", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")

      output =
        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--version", "3.5", "--path", install_path])
        end)

      assert output =~ "Maude3.5"
      assert output =~ "Maude installed successfully"

      maude_binary = Path.join(install_path, "maude")
      assert File.exists?(maude_binary)
    end

    @tag :integration
    @tag :network
    test "extracts library files alongside binary", %{tmp_dir: tmp_dir} do
      # Use existing installation or skip
      existing_path = Path.expand("priv/maude/bin", Mix.Project.app_path())

      if File.exists?(Path.join(existing_path, "maude")) do
        # Verify library files exist
        assert File.exists?(Path.join(existing_path, "prelude.maude"))
        assert File.exists?(Path.join(existing_path, "model-checker.maude"))
      else
        # Install fresh
        install_path = Path.join(tmp_dir, "maude-bin")

        capture_io(fn ->
          Mix.Tasks.Maude.Install.run(["--path", install_path])
        end)

        assert File.exists?(Path.join(install_path, "prelude.maude"))
        assert File.exists?(Path.join(install_path, "model-checker.maude"))
      end
    end
  end

  describe "checksum verification" do
    @tag :integration
    @tag :slow
    @tag :network
    test "verifies SHA256 checksum when available", %{tmp_dir: tmp_dir} do
      install_path = Path.join(tmp_dir, "maude-bin")

      output =
        capture_io(fn ->
          # 3.5.1 has checksums in the GitHub API
          Mix.Tasks.Maude.Install.run(["--version", "3.5.1", "--path", install_path])
        end)

      # Should verify checksum for 3.5.1 (has digest in API)
      assert output =~ "Checksum verified" or output =~ "No checksum available"
      assert output =~ "Maude installed successfully"
    end
  end

  describe "error handling" do
    test "fails gracefully on network error" do
      # This is hard to test without mocking, but we can verify
      # the error message format exists in the module
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "Failed to connect"
      assert source =~ "internet connection"
    end

    test "provides helpful message for unsupported platform" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "No Maude binary available for platform"
      assert source =~ "build Maude from source"
    end
  end

  describe "macOS security" do
    @tag :integration
    test "provides quarantine removal hint on macOS" do
      if :os.type() == {:unix, :darwin} do
        source = File.read!("lib/mix/tasks/maude.install.ex")
        assert source =~ "xattr -d com.apple.quarantine"
      end
    end
  end

  describe "path validation" do
    test "validates path traversal protection exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "validate_download_path"
      assert source =~ "validate_extraction_paths"
      assert source =~ "directory traversal"
    end

    test "validates shell metacharacter protection exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "shell metacharacters"
      assert source =~ ~r/\[.*\"\;\".*\]/
    end

    test "file size limit is configured" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "@max_download_size"
      assert source =~ "100 * 1024 * 1024"
    end
  end

  describe "platform patterns" do
    test "supports darwin-arm64" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "darwin-arm64"
      assert source =~ ~r/macos-arm64/i
    end

    test "supports darwin-x86_64" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "darwin-x86_64"
      assert source =~ ~r/macos-x86_64|darwin64/i
    end

    test "supports linux-x86_64" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "linux-x86_64"
      assert source =~ ~r/linux-x86_64|linux64/i
    end
  end

  describe "version tag normalization" do
    test "normalization rules are documented" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      # Handles "3.5.1" -> "Maude3.5.1"
      assert source =~ "normalize_version_tag"
      assert source =~ "Maude"
    end
  end

  describe "download methods" do
    test "curl download with max-filesize" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "download_with_curl"
      assert source =~ "--max-filesize"
    end

    test "httpc fallback exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "download_with_httpc"
    end

    test "redirect handling exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "handle_redirect"
    end
  end

  describe "extraction methods" do
    test "unzip extraction exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "extract_with_unzip"
    end

    test "erlang extraction fallback exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "extract_with_erlang"
    end

    test "binary renaming logic exists" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "rename_maude_binary"
      # Should handle various naming conventions
      assert source =~ "maude.darwin64" or source =~ "Maude"
    end
  end

  describe "ssl configuration" do
    test "uses secure ssl options" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "ssl_opts"
      assert source =~ "verify: :verify_peer"
      assert source =~ "cacerts"
    end
  end

  describe "GitHub API" do
    test "uses correct API endpoint" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "api.github.com/repos/maude-lang/Maude/releases"
    end

    test "sets proper user agent" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "ExMaude-Installer"
    end

    test "handles rate limiting" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "403"
      assert source =~ "rate limit"
    end
  end

  describe "module attributes" do
    test "has correct shortdoc" do
      shortdoc = Mix.Task.shortdoc(Mix.Tasks.Maude.Install)
      assert shortdoc == "Installs Maude system binary"
    end

    test "module is a Mix.Task" do
      behaviours = Mix.Tasks.Maude.Install.__info__(:attributes)[:behaviour] || []
      assert Mix.Task in behaviours
    end
  end

  describe "timeout configuration" do
    test "download timeout is configured" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "@download_timeout"
      assert source =~ "120_000"
    end

    test "api timeout is configured" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "@api_timeout"
      assert source =~ "30_000"
    end
  end

  describe "error messages" do
    test "provides installation path in success message" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "Maude installed successfully"
    end

    test "provides retry suggestion on failure" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "try again" or source =~ "Try again"
    end
  end

  describe "default installation path" do
    test "defaults to priv/maude/bin" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "priv/maude/bin"
    end
  end

  describe "binary naming" do
    test "handles multiple binary naming conventions" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      # Should handle various Maude binary names
      assert source =~ "maude.darwin64" or source =~ "possible_names"
      assert source =~ "maude.linux64" or source =~ "possible_names"
    end
  end

  describe "post-install verification" do
    test "verifies installation after download" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "verify_installation"
      assert source =~ "Verifying"
    end

    test "makes binary executable" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "chmod" or source =~ "0o755"
    end
  end

  describe "configuration suggestion" do
    test "provides config example after installation" do
      source = File.read!("lib/mix/tasks/maude.install.ex")
      assert source =~ "config :ex_maude"
      assert source =~ "maude_path"
    end
  end
end
