defmodule Mix.Tasks.Maude.Install do
  @moduledoc """
  Installs or updates Maude system binary.

  ExMaude bundles Maude binaries for common platforms, so this task is typically
  only needed when:

    * The bundled binary doesn't exist for your platform
    * You want to install a different Maude version
    * You want to install to a custom location

  ## Usage

      mix maude.install [--version VERSION] [--path PATH] [--force] [--list] [--check]

  ## Options

    * `--version` - Maude version to install (default: latest)
    * `--path` - Installation path (default: ./priv/maude/bin)
    * `--force` - Force reinstall even if already installed
    * `--list` - List available versions and exit
    * `--check` - Check current Maude availability and exit

  ## Supported Platforms

    * macOS ARM64 (Apple Silicon)
    * macOS x86_64 (Intel)
    * Linux x86_64
    * Linux ARM64

  ## Examples

      # Check if Maude is available
      mix maude.install --check

      # Install latest version (only if needed)
      mix maude.install

      # List available versions
      mix maude.install --list

      # Install specific version
      mix maude.install --version 3.5.1

      # Install to custom path
      mix maude.install --path /usr/local/bin

      # Force reinstall
      mix maude.install --force

  ## Bundled Binaries

  ExMaude includes platform-specific Maude binaries in `priv/maude/bin/`:

      priv/maude/bin/
      ├── maude-darwin-arm64    # macOS Apple Silicon
      ├── maude-darwin-x64      # macOS Intel
      ├── maude-linux-x64       # Linux x86_64
      └── maude-linux-arm64     # Linux ARM64

  The binary resolution follows this priority:

    1. `config :ex_maude, :maude_path` - Explicit configuration
    2. Bundled binary for current platform
    3. System PATH (`maude` command)

  ## Troubleshooting

  If installation fails:

    * **Network errors** - Check your internet connection and proxy settings
    * **Permission denied** - Ensure you have write access to the installation path
    * **Platform not supported** - Check if your OS/architecture is in the supported list
    * **Verification failed** - The binary may require additional system libraries

  For macOS, you may need to allow the binary in System Preferences > Security & Privacy
  if you see a "cannot be opened because the developer cannot be verified" error.
  """

  use Mix.Task

  @shortdoc "Installs Maude system binary"

  @github_api "https://api.github.com/repos/maude-lang/Maude/releases"
  @download_timeout 120_000
  @api_timeout 30_000
  @max_download_size 100 * 1024 * 1024

  # Platform patterns for matching asset names across different release naming conventions
  @platform_patterns %{
    "darwin-arm64" => [
      ~r/macos-arm64\.zip$/i,
      ~r/macos-arm\.zip$/i,
      ~r/darwin-arm64\.zip$/i,
      ~r/darwin64-arm\.zip$/i
    ],
    "darwin-x86_64" => [
      ~r/macos-x86_64\.zip$/i,
      ~r/macos\.zip$/i,
      ~r/darwin-x86_64\.zip$/i,
      ~r/darwin64\.zip$/i
    ],
    "linux-x86_64" => [
      ~r/linux-x86_64\.zip$/i,
      ~r/linux\.zip$/i,
      ~r/linux64\.zip$/i
    ]
  }

  # coveralls-ignore-start
  # Mix task - tested via integration tests with :network tag

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          version: :string,
          path: :string,
          force: :boolean,
          list: :boolean,
          check: :boolean
        ]
      )

    if invalid != [] do
      invalid_opts = Enum.map_join(invalid, ", ", fn {opt, _} -> opt end)
      Mix.raise("Unknown options: #{invalid_opts}\n\nRun `mix help maude.install` for usage.")
    end

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:public_key)

    cond do
      Keyword.get(opts, :check, false) ->
        check_availability()

      Keyword.get(opts, :list, false) ->
        list_versions()

      true ->
        version = Keyword.get(opts, :version)
        install_path = Keyword.get(opts, :path, default_install_path())
        force = Keyword.get(opts, :force, false)

        maude_binary = Path.join(install_path, "maude")

        if File.exists?(maude_binary) and not force do
          Mix.shell().info("Maude already installed at #{maude_binary}")
          Mix.shell().info("Use --force to reinstall")
          :ok
        else
          install_maude(version, install_path)
        end
    end
  end

  defp check_availability do
    Mix.shell().info("Checking Maude availability...")
    Mix.shell().info("")

    platform = detect_platform()
    Mix.shell().info("Platform: #{platform}")

    # Check bundled binary
    bundled_path = ExMaude.Binary.bundled_path()

    if bundled_path do
      Mix.shell().info("✓ Bundled binary: #{bundled_path}")
    else
      Mix.shell().info("✗ Bundled binary: not found for #{platform}")
    end

    # Check system PATH
    system_path = System.find_executable("maude")

    if system_path do
      Mix.shell().info("✓ System PATH: #{system_path}")
    else
      Mix.shell().info("✗ System PATH: maude not found")
    end

    # Check configured path
    configured = Application.get_env(:ex_maude, :maude_path)

    if configured do
      if File.exists?(configured) do
        Mix.shell().info("✓ Configured: #{configured}")
      else
        Mix.shell().info("✗ Configured: #{configured} (file not found)")
      end
    end

    # Final resolution
    Mix.shell().info("")

    case ExMaude.Binary.find() do
      nil ->
        Mix.shell().error("✗ No Maude binary available")
        Mix.shell().info("")
        Mix.shell().info("Install with: mix maude.install")

      path ->
        Mix.shell().info("✓ ExMaude will use: #{path}")
    end
  end

  defp list_versions do
    Mix.shell().info("Fetching available Maude versions...")

    case fetch_releases() do
      {:ok, releases} ->
        platform = detect_platform()
        Mix.shell().info("\nAvailable Maude versions for #{platform}:\n")

        releases
        |> Enum.filter(&has_platform_asset?(&1, platform))
        |> Enum.each(fn release ->
          tag = release["tag_name"]
          name = release["name"]
          date = release["published_at"] |> String.slice(0, 10)
          latest = if release["prerelease"] == false, do: "", else: " (prerelease)"
          Mix.shell().info("  #{tag} - #{name} (#{date})#{latest}")
        end)

        Mix.shell().info("\nInstall with: mix maude.install --version <VERSION>")
        Mix.shell().info("Example: mix maude.install --version 3.5.1")

      {:error, reason} ->
        Mix.raise("Failed to fetch releases: #{reason}")
    end
  end

  defp default_install_path do
    Path.join([Mix.Project.build_path(), "..", "..", "priv", "maude", "bin"])
    |> Path.expand()
  end

  defp install_maude(version, install_path) do
    platform = detect_platform()

    Mix.shell().info("Detecting platform: #{platform}")
    Mix.shell().info("Fetching release information from GitHub...")

    case find_release_asset(version, platform) do
      {:ok, %{url: url, sha256: sha256, version: resolved_version}} ->
        Mix.shell().info("Installing Maude #{resolved_version} for #{platform}...")

        File.mkdir_p!(install_path)

        tmp_dir = System.tmp_dir!()
        zip_path = Path.join(tmp_dir, "maude-#{resolved_version}-#{platform}.zip")

        download_file(url, zip_path)
        verify_checksum(zip_path, sha256)
        extract_and_install(zip_path, install_path, resolved_version)

        File.rm(zip_path)

        maude_binary = Path.join(install_path, "maude")
        File.chmod!(maude_binary, 0o755)

        Mix.shell().info("\n✓ Maude installed successfully at #{maude_binary}")
        verify_installation(maude_binary)

      {:error, :no_releases} ->
        Mix.raise("""
        Failed to fetch releases from GitHub.

        Please check your internet connection and try again.
        You can also manually download Maude from:
        https://github.com/maude-lang/Maude/releases
        """)

      {:error, :version_not_found, available} ->
        Mix.raise("""
        Version "#{version}" not found.

        Available versions:
          #{Enum.join(available, "\n  ")}

        Run `mix maude.install --list` for more details.
        """)

      {:error, :platform_not_supported, available_platforms} ->
        Mix.raise("""
        No Maude binary available for platform: #{platform}

        Your system:
          OS: #{elem(:os.type(), 1)}
          Architecture: #{:erlang.system_info(:system_architecture)}

        Available platforms for this version:
          #{Enum.join(available_platforms, "\n  ")}

        You may need to build Maude from source for your platform.
        See: https://github.com/maude-lang/Maude
        """)
    end
  end

  defp find_release_asset(nil, platform) do
    # Find latest stable release
    case fetch_releases() do
      {:ok, releases} ->
        releases
        |> Enum.filter(&(&1["prerelease"] == false))
        |> Enum.find_value(fn release ->
          case find_asset_for_platform(release, platform) do
            {:ok, asset} ->
              {:ok,
               %{
                 url: asset["browser_download_url"],
                 sha256: parse_sha256(asset["digest"]),
                 version: release["tag_name"]
               }}

            :error ->
              nil
          end
        end)
        |> case do
          nil -> {:error, :platform_not_supported, get_all_platforms(releases)}
          result -> result
        end

      {:error, _} ->
        {:error, :no_releases}
    end
  end

  defp find_release_asset(version, platform) do
    # Normalize version format (handle both "3.5.1" and "Maude3.5.1")
    version_tag = normalize_version_tag(version)

    case fetch_releases() do
      {:ok, releases} ->
        case Enum.find(releases, &(&1["tag_name"] == version_tag)) do
          nil ->
            available =
              releases
              |> Enum.filter(&(&1["prerelease"] == false))
              |> Enum.map(& &1["tag_name"])

            {:error, :version_not_found, available}

          release ->
            case find_asset_for_platform(release, platform) do
              {:ok, asset} ->
                {:ok,
                 %{
                   url: asset["browser_download_url"],
                   sha256: parse_sha256(asset["digest"]),
                   version: release["tag_name"]
                 }}

              :error ->
                available_platforms = get_release_platforms(release)
                {:error, :platform_not_supported, available_platforms}
            end
        end

      {:error, _} ->
        {:error, :no_releases}
    end
  end

  defp normalize_version_tag(version) do
    cond do
      String.starts_with?(version, "Maude") -> version
      String.starts_with?(version, "maude") -> "Maude" <> String.slice(version, 5..-1//1)
      String.match?(version, ~r/^\d/) -> "Maude#{version}"
      true -> version
    end
  end

  defp find_asset_for_platform(release, platform) do
    patterns = Map.get(@platform_patterns, platform, [])
    assets = release["assets"] || []

    Enum.find_value(assets, :error, fn asset ->
      name = asset["name"]

      if Enum.any?(patterns, &Regex.match?(&1, name)) do
        {:ok, asset}
      else
        nil
      end
    end)
  end

  defp has_platform_asset?(release, platform) do
    case find_asset_for_platform(release, platform) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp get_release_platforms(release) do
    assets = release["assets"] || []

    Enum.flat_map(@platform_patterns, fn {platform, patterns} ->
      if Enum.any?(assets, fn asset ->
           Enum.any?(patterns, &Regex.match?(&1, asset["name"]))
         end) do
        [platform]
      else
        []
      end
    end)
  end

  defp get_all_platforms(releases) do
    releases
    |> Enum.flat_map(&get_release_platforms/1)
    |> Enum.uniq()
  end

  defp parse_sha256(nil), do: nil
  defp parse_sha256("sha256:" <> hash), do: hash
  defp parse_sha256(_), do: nil

  defp fetch_releases do
    url = String.to_charlist(@github_api)

    headers = [
      {~c"User-Agent", ~c"ExMaude-Installer"},
      {~c"Accept", ~c"application/vnd.github.v3+json"}
    ]

    http_opts = [
      ssl: ssl_opts(),
      timeout: @api_timeout,
      autoredirect: true
    ]

    case :httpc.request(:get, {url, headers}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, {{_, 403, _}, _, _}} ->
        {:error, "GitHub API rate limit exceeded. Try again later."}

      {:ok, {{_, status, reason}, _, _}} ->
        {:error, "HTTP #{status} #{reason}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp detect_platform do
    arch =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64" <> _ -> "arm64"
        "arm64" <> _ -> "arm64"
        "x86_64" <> _ -> "x86_64"
        "amd64" <> _ -> "x86_64"
        other -> other
      end

    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, :linux} -> "linux"
        {:win32, _} -> "windows"
        {_, os} -> to_string(os)
      end

    "#{os}-#{arch}"
  end

  defp download_file(url, destination) do
    Mix.shell().info("Downloading from: #{url}")

    with :ok <- validate_download_path(destination) do
      # Use curl if available for better redirect handling and progress
      case System.find_executable("curl") do
        nil -> download_with_httpc(url, destination)
        curl -> download_with_curl(curl, url, destination)
      end
    end
  end

  defp validate_download_path(path) do
    expanded = Path.expand(path)
    tmp_dir = Path.expand(System.tmp_dir!())

    cond do
      String.contains?(path, ["../", "..\\"]) ->
        Mix.raise("Invalid path: contains directory traversal")

      not String.starts_with?(expanded, tmp_dir) ->
        Mix.raise("Invalid path: must be within temp directory")

      true ->
        :ok
    end
  end

  defp download_with_curl(curl, url, destination) do
    args = [
      "-fSL",
      "--progress-bar",
      "--max-filesize",
      Integer.to_string(@max_download_size),
      "-o",
      destination,
      url
    ]

    case System.cmd(curl, args, stderr_to_stdout: true) do
      {_, 0} ->
        validate_downloaded_file(destination)

      {output, code} ->
        Mix.raise("""
        Failed to download Maude (curl exit code: #{code})

        #{String.trim(output)}

        URL: #{url}
        """)
    end
  end

  defp validate_downloaded_file(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_download_size ->
        File.rm(path)

        Mix.raise("""
        Downloaded file exceeds maximum size limit.

        Size: #{div(size, 1024 * 1024)} MB
        Limit: #{div(@max_download_size, 1024 * 1024)} MB
        """)

      {:ok, %{size: size}} ->
        size_kb = div(size, 1024)
        Mix.shell().info("Downloaded #{size_kb} KB")
        :ok

      {:error, reason} ->
        Mix.raise("Failed to verify downloaded file: #{inspect(reason)}")
    end
  end

  defp download_with_httpc(url, destination) do
    url_charlist = String.to_charlist(url)

    http_opts = [
      ssl: ssl_opts(),
      timeout: @download_timeout,
      autoredirect: true
    ]

    case :httpc.request(:get, {url_charlist, []}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} when byte_size(body) > @max_download_size ->
        Mix.raise("""
        Downloaded file exceeds maximum size limit.

        Size: #{div(byte_size(body), 1024 * 1024)} MB
        Limit: #{div(@max_download_size, 1024 * 1024)} MB
        """)

      {:ok, {{_, 200, _}, _headers, body}} ->
        File.write!(destination, body)
        size_kb = div(byte_size(body), 1024)
        Mix.shell().info("Downloaded #{size_kb} KB")
        :ok

      {:ok, {{_, 302, _}, headers, _}} ->
        handle_redirect(headers, destination)

      {:ok, {{_, 301, _}, headers, _}} ->
        handle_redirect(headers, destination)

      {:ok, {{_, status, reason}, _, _}} ->
        Mix.raise("""
        Failed to download Maude: HTTP #{status} #{reason}

        URL: #{url}

        This may be a temporary issue. Please try again later.
        """)

      {:error, {:failed_connect, _}} ->
        Mix.raise("""
        Failed to connect to download server.

        Please check:
          * Your internet connection
          * Firewall or proxy settings
          * That github.com is accessible
        """)

      {:error, :timeout} ->
        Mix.raise("""
        Download timed out after #{div(@download_timeout, 1000)} seconds.

        The file may be large or your connection slow. Try again or download manually.
        """)

      {:error, reason} ->
        Mix.raise("""
        Failed to download Maude: #{inspect(reason)}

        URL: #{url}
        """)
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp handle_redirect(headers, destination) do
    location =
      headers
      |> Enum.find(fn {key, _} -> String.downcase(to_string(key)) == "location" end)
      |> elem(1)
      |> to_string()

    download_with_httpc(location, destination)
  end

  defp verify_checksum(_path, nil) do
    Mix.shell().info("(No checksum available, skipping verification)")
    :ok
  end

  defp verify_checksum(path, expected_sha) do
    Mix.shell().info("Verifying checksum...")

    actual_sha =
      File.stream!(path, 2048)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual_sha == expected_sha do
      Mix.shell().info("✓ Checksum verified")
      :ok
    else
      File.rm(path)

      Mix.raise("""
      Checksum verification failed!

      Expected: #{expected_sha}
      Got:      #{actual_sha}

      The downloaded file may be corrupted or tampered with.
      Please try again or report this issue.
      """)
    end
  end

  defp extract_and_install(zip_path, install_path, version) do
    Mix.shell().info("Extracting...")

    with :ok <- validate_extraction_paths(zip_path, install_path) do
      # Use system unzip for better compatibility with various zip formats
      case System.find_executable("unzip") do
        nil ->
          extract_with_erlang(zip_path, install_path, version)

        unzip ->
          extract_with_unzip(unzip, zip_path, install_path, version)
      end
    end
  end

  defp validate_extraction_paths(zip_path, install_path) do
    expanded_zip = Path.expand(zip_path)
    expanded_install = Path.expand(install_path)
    tmp_dir = Path.expand(System.tmp_dir!())
    cwd = Path.expand(File.cwd!())

    # Validate paths don't contain shell metacharacters
    shell_chars = [";", "|", "&", "`", "$(", "${"]

    cond do
      Enum.any?(shell_chars, &String.contains?(zip_path, &1)) ->
        Mix.raise("Invalid zip path: contains shell metacharacters")

      Enum.any?(shell_chars, &String.contains?(install_path, &1)) ->
        Mix.raise("Invalid install path: contains shell metacharacters")

      not String.starts_with?(expanded_zip, tmp_dir) ->
        Mix.raise("Invalid zip path: must be within temp directory")

      not (String.starts_with?(expanded_install, cwd) or
               String.starts_with?(expanded_install, tmp_dir)) ->
        Mix.raise("Invalid install path: must be within project or temp directory")

      true ->
        :ok
    end
  end

  defp extract_with_unzip(unzip, zip_path, install_path, _version) do
    # -o: overwrite without prompting
    # -q: quiet
    args = ["-o", "-q", zip_path, "-d", install_path]

    case System.cmd(unzip, args, stderr_to_stdout: true) do
      {_, 0} ->
        files = File.ls!(install_path)
        Mix.shell().info("Extracted #{length(files)} files")

        # Check if maude binary exists and is executable
        maude_path = Path.join(install_path, "maude")

        if File.exists?(maude_path) do
          :ok
        else
          Mix.raise("""
          Extraction succeeded but 'maude' binary not found.

          Extracted files: #{inspect(files)}

          This may indicate an issue with the release package.
          """)
        end

      {output, code} ->
        Mix.raise("""
        Failed to extract archive (unzip exit code: #{code})

        #{String.trim(output)}
        """)
    end
  end

  defp extract_with_erlang(zip_path, install_path, version) do
    case :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(install_path)) do
      {:ok, files} ->
        Mix.shell().info("Extracted #{length(files)} files")
        rename_maude_binary(install_path, version)
        :ok

      {:error, :einval} ->
        Mix.raise("""
        Failed to extract: Invalid or corrupted ZIP file.

        Try running with --force to re-download.
        """)

      {:error, reason} ->
        Mix.raise("Failed to extract archive: #{inspect(reason)}")
    end
  end

  defp rename_maude_binary(install_path, version) do
    target = Path.join(install_path, "maude")

    # Remove existing target if present
    if File.exists?(target), do: File.rm!(target)

    # Try to find the maude binary with various naming conventions
    possible_names = [
      # 3.5+ naming
      "maude.darwin64",
      "maude.linux64",
      "maude.arm64",
      # Older naming
      "maude-Yices2",
      "Maude",
      "maude",
      # Version-specific
      "maude-#{version}",
      "Maude-#{version}"
    ]

    found =
      Enum.find_value(possible_names, fn name ->
        source = Path.join(install_path, name)

        if File.exists?(source) and not File.dir?(source) do
          File.rename!(source, target)
          true
        else
          nil
        end
      end)

    unless found do
      # List what we actually extracted
      files =
        File.ls!(install_path)
        |> Enum.reject(&File.dir?(Path.join(install_path, &1)))

      Mix.shell().error("""
      Warning: Could not find Maude binary to rename.
      Extracted files: #{inspect(files)}

      You may need to manually rename the correct file to 'maude'.
      """)
    end
  end

  defp verify_installation(maude_binary) do
    Mix.shell().info("Verifying installation...")

    # Try --version first, then --help, then just running it
    verify_commands = [
      ["--version"],
      ["--help"],
      []
    ]

    result =
      Enum.find_value(verify_commands, fn args ->
        case System.cmd(maude_binary, args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, _} ->
            # Some Maude versions exit non-zero for --version/--help but still work
            if String.contains?(output, "Maude") do
              {:ok, output}
            else
              nil
            end
        end
      end)

    case result do
      {:ok, output} ->
        version_line =
          output
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, "Maude"))
          |> case do
            nil -> "Maude"
            line -> String.trim(line)
          end

        Mix.shell().info("✓ Verified: #{version_line}")

        # Print helpful configuration info
        Mix.shell().info("""

        Add to your config/config.exs:

            config :ex_maude,
              maude_path: "#{maude_binary}"

        Or set MAUDE_PATH environment variable.
        """)

      nil ->
        Mix.shell().error("""
        Warning: Maude verification failed.

        The binary may still work. Common issues:

        macOS: You may need to allow the binary in System Preferences > Security & Privacy
               Run: xattr -d com.apple.quarantine #{maude_binary}

        Linux: You may need to install additional libraries:
          Ubuntu/Debian: sudo apt-get install libgmp10 libncurses5
          Fedora/RHEL:   sudo dnf install gmp ncurses-compat-libs
        """)
    end
  end

  # coveralls-ignore-stop
end
