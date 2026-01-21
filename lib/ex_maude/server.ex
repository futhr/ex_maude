defmodule ExMaude.Server do
  @moduledoc """
  GenServer that manages a single Maude process.

  This module delegates to the configured backend (Port, C-Node, or NIF).
  See `ExMaude.Backend` for backend selection.

  ## Architecture

  Each Server maintains a persistent Maude session. Commands are sent via
  the configured backend and responses are collected until complete.

  ## Usage

  This module is typically used via `ExMaude.Pool` rather than directly:

      {:ok, pid} = ExMaude.Server.start_link([])
      {:ok, result} = ExMaude.Server.execute(pid, "reduce in NAT : 1 + 2 .")

  ## Configuration

  The following options can be passed to `start_link/1`:

    * `:maude_path` - Path to Maude executable (default: bundled or from config)
    * `:preload_modules` - List of Maude files to load on startup
    * `:timeout` - Default command timeout in ms (default: 5000)

  ## Application Configuration

      config :ex_maude,
        backend: :port,              # :port | :cnode | :nif
        maude_path: nil,             # nil = auto-detect bundled binary
        use_pty: true                # For Port backend only

  """

  alias ExMaude.Backend

  @default_timeout_ms 5_000

  @doc """
  Starts a new Maude server process using the configured backend.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Backend.impl().start_link(opts)
  end

  @doc """
  Executes a Maude command and waits for the result.

  ## Options

    * `:timeout` - Maximum time to wait in ms (default: 5000)
  """
  @spec execute(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(server, command, opts \\ []) do
    Backend.impl().execute(server, command, opts)
  end

  @doc """
  Loads a Maude file into this server's session.
  """
  @spec load_file(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def load_file(server, path) do
    Backend.impl().load_file(server, path)
  end

  @doc """
  Checks if the Maude process is alive.
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    Backend.impl().alive?(server)
  end

  @doc """
  Stops the Maude server.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    Backend.impl().stop(server)
  end

  @doc """
  Returns the default timeout in milliseconds.
  """
  @spec default_timeout() :: 5000
  def default_timeout, do: @default_timeout_ms
end
