defmodule ExMaude.Backend do
  @moduledoc """
  Behaviour for ExMaude communication backends.

  All backends must implement this behaviour to be used
  interchangeably by the ExMaude API. This enables swapping
  between different communication strategies:

    * `:port` - Erlang Port with PTY wrapper (default, safe)
    * `:cnode` - C-Node with binary protocol (production)
    * `:nif` - Native Implemented Function (fastest, Phase 3)

  ## Configuration

      config :ex_maude,
        backend: :port  # :port | :cnode | :nif

  ## Example

      # Get the configured backend module
      backend = ExMaude.Backend.impl()

      # Start a worker
      {:ok, server} = backend.start_link([])

      # Execute a command
      {:ok, result} = backend.execute(server, "reduce in NAT : 1 + 2 .")

  """

  @type command :: String.t()
  @type result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Starts a backend worker process.

  ## Options

    * `:maude_path` - Path to Maude executable (optional)
    * `:timeout` - Default command timeout in ms
    * `:preload_modules` - List of Maude files to load on startup

  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Executes a Maude command and returns the result.

  ## Options

    * `:timeout` - Maximum time to wait in ms

  """
  @callback execute(server :: GenServer.server(), command(), keyword()) :: result()

  @doc """
  Checks if the backend worker is alive and ready.
  """
  @callback alive?(server :: GenServer.server()) :: boolean()

  @doc """
  Loads a Maude file into the session.
  """
  @callback load_file(server :: GenServer.server(), path :: Path.t()) :: :ok | {:error, term()}

  @doc """
  Stops the backend worker.
  """
  @callback stop(server :: GenServer.server()) :: :ok

  @typedoc "Backend module types"
  @type backend_module :: ExMaude.Backend.Port | ExMaude.Backend.CNode | ExMaude.Backend.NIF

  @typedoc "Backend configuration atoms"
  @type backend_type :: :port | :cnode | :nif

  @doc """
  Returns the backend implementation module based on configuration.

  ## Examples

      iex> ExMaude.Backend.impl()
      ExMaude.Backend.Port

  """
  @spec impl() :: backend_module()
  def impl do
    case Application.get_env(:ex_maude, :backend, :port) do
      :port -> ExMaude.Backend.Port
      :cnode -> ExMaude.Backend.CNode
      :nif -> ExMaude.Backend.NIF
    end
  end

  @doc """
  Checks if a backend is available on this system.

  ## Examples

      iex> ExMaude.Backend.available?(:port)
      true

      iex> ExMaude.Backend.available?(:cnode)
      # Until maude_bridge is compiled
      false

  """
  @spec available?(backend_type()) :: boolean()
  def available?(:port), do: true

  def available?(:cnode) do
    bridge_path = cnode_binary()
    File.exists?(bridge_path) and executable?(bridge_path)
  end

  def available?(:nif) do
    # NIF backend requires the native Rustler module to be compiled
    # The stub module always exists, but the native implementation doesn't yet
    Code.ensure_loaded?(ExMaude.Backend.NIF.Native) and
      function_exported?(ExMaude.Backend.NIF.Native, :initialize, 1)
  end

  @doc """
  Returns a list of all available backends on this system.
  """
  @spec available_backends() :: [atom()]
  def available_backends do
    Enum.filter([:port, :cnode, :nif], &available?/1)
  end

  @doc """
  Returns the path to the C-Node bridge binary.
  """
  @spec cnode_binary() :: Path.t()
  def cnode_binary do
    priv_dir = :code.priv_dir(:ex_maude)
    Path.join(priv_dir, "maude_bridge")
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) > 0
      _ -> false
    end
  end
end
