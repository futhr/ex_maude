defmodule ExMaude.Binary do
  @moduledoc """
  Maude binary management and platform detection.

  This module handles locating and managing Maude executables, with support for:
  - Bundled platform-specific binaries
  - System PATH detection
  - Custom path configuration

  ## Bundled Binaries

  ExMaude bundles Maude binaries for common platforms in `priv/maude/bin/`:

      priv/maude/bin/
      ├── maude-darwin-arm64    # macOS Apple Silicon
      ├── maude-darwin-x64      # macOS Intel
      └── maude-linux-x64       # Linux x86_64

  ## Fallback Chain

  Binary resolution follows this priority:

  1. `Application.get_env(:ex_maude, :maude_path)` - Explicit config
  2. `priv/maude/bin/maude-{platform}` - Bundled binary
  3. `System.find_executable("maude")` - System PATH
  4. Raises error with install instructions

  ## Examples

      # Get the Maude binary path
      ExMaude.Binary.path()
      #=> "/path/to/ex_maude/priv/maude/bin/maude-darwin-arm64"

      # Check if bundled binary is available
      ExMaude.Binary.bundled?()
      #=> true

      # Get current platform
      ExMaude.Binary.platform()
      #=> "darwin-arm64"

  """

  @version "3.5.1"

  @doc """
  Returns the path to the Maude binary.

  Follows the fallback chain: config → bundled → system → error.

  ## Examples

      ExMaude.Binary.path()
      #=> "/path/to/maude"

  """
  @spec path() :: Path.t()
  def path do
    case find() do
      nil -> raise_not_found()
      found -> found
    end
  end

  @doc """
  Returns the path to the Maude binary, or nil if not found.

  Unlike `path/0`, this does not raise an error.
  """
  @spec find() :: Path.t() | nil
  def find do
    configured_path() || bundled_path() || system_path()
  end

  @doc """
  Returns the bundled Maude version.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Checks if a bundled Maude binary is available for the current platform.
  """
  @spec bundled?() :: boolean()
  def bundled? do
    bundled_path() != nil
  end

  @doc """
  Returns the current platform identifier.

  ## Examples

      ExMaude.Binary.platform()
      #=> "darwin-arm64"

  """
  @spec platform() :: String.t()
  def platform do
    case {:os.type(), system_architecture()} do
      {{:unix, :darwin}, arch} when arch in ["aarch64", "arm64", "arm"] ->
        "darwin-arm64"

      {{:unix, :darwin}, _} ->
        "darwin-x64"

      # coveralls-ignore-start
      # Platform-specific branches - only the current platform is testable
      {{:unix, :linux}, arch} when arch in ["x86_64", "amd64"] ->
        "linux-x64"

      {{:unix, :linux}, arch} when arch in ["aarch64", "arm64", "arm"] ->
        "linux-arm64"

      {os, arch} ->
        "#{elem(os, 1)}-#{arch}"
        # coveralls-ignore-stop
    end
  end

  @doc """
  Returns the priv directory path for ExMaude.
  """
  @spec priv_dir() :: Path.t()
  def priv_dir do
    case :code.priv_dir(:ex_maude) do
      # coveralls-ignore-start
      # Only reached when app is not loaded (rare edge case)
      {:error, :bad_name} ->
        # Fallback for development
        Path.join([File.cwd!(), "priv"])

      # coveralls-ignore-stop
      path ->
        to_string(path)
    end
  end

  @doc """
  Returns the path to the bundled Maude binary for the current platform, or nil.
  """
  @spec bundled_path() :: Path.t() | nil
  def bundled_path do
    platform_binary = "maude-#{platform()}"
    path = Path.join([priv_dir(), "maude", "bin", platform_binary])

    if File.exists?(path) and executable?(path) do
      path
    else
      # coveralls-ignore-start
      # Fallback to generic binary - depends on bundled file state
      # Also check for generic "maude" binary
      generic = Path.join([priv_dir(), "maude", "bin", "maude"])

      if File.exists?(generic) and executable?(generic) do
        generic
      else
        nil
      end

      # coveralls-ignore-stop
    end
  end

  @doc """
  Returns all supported platforms.
  """
  @spec supported_platforms() :: [String.t()]
  def supported_platforms do
    ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"]
  end

  @doc """
  Checks if the current platform is supported.
  """
  @spec supported_platform?() :: boolean()
  def supported_platform? do
    platform() in supported_platforms()
  end

  # Private functions

  defp configured_path do
    case Application.get_env(:ex_maude, :maude_path) do
      nil -> nil
      path when is_binary(path) -> validate_path(path)
    end
  end

  defp system_path do
    case System.find_executable("maude") do
      nil -> nil
      path -> path
    end
  end

  defp validate_path(path) do
    expanded = Path.expand(path)

    cond do
      not File.exists?(expanded) -> nil
      not executable?(expanded) -> nil
      true -> expanded
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) > 0
      _ -> false
    end
  end

  defp system_architecture do
    :erlang.system_info(:system_architecture)
    |> to_string()
    |> String.split("-")
    |> List.first()
  end

  @spec raise_not_found() :: no_return()
  defp raise_not_found do
    raise """
    Maude executable not found.

    ExMaude looks for Maude in the following order:
    1. config :ex_maude, :maude_path
    2. Bundled binary at priv/maude/bin/maude-#{platform()}
    3. System PATH

    To install Maude:
      mix maude.install

    Or download manually from:
      https://github.com/maude-lang/Maude/releases

    Current platform: #{platform()}
    Supported platforms: #{Enum.join(supported_platforms(), ", ")}
    """
  end
end
