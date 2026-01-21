defmodule ExMaude.Backend.NIF do
  @moduledoc """
  NIF-based backend for ExMaude using Rustler.

  > #### Work in Progress {: .warning}
  >
  > This backend is under active development (Phase 3). For production use,
  > configure the `:port` backend instead:
  >
  >     config :ex_maude, backend: :port

  This backend manages a Maude subprocess from Rust, providing lower latency
  than the Port backend by avoiding Elixir process overhead.

  ## Features

    * Lower latency than Port backend
    * Uses Rust dirty CPU schedulers for I/O operations
    * Managed subprocess with synchronized I/O

  ## Trade-offs

    * **No process isolation** - NIF crash takes down the BEAM
    * Requires Rust toolchain for compilation
    * More complex deployment than Port backend

  ## Configuration

      config :ex_maude,
        backend: :nif

  ## Safety Considerations

  NIFs run in the same OS process as the BEAM. A crash in the NIF (segfault,
  panic, etc.) will crash the entire Erlang VM. This backend should only be
  used after profiling proves the latency improvement is necessary.

  Recommended usage:
  1. Start with `:port` backend (default, safest)
  2. Profile your application
  3. Switch to `:cnode` for binary protocol benefits
  4. Only use `:nif` if latency is critical

  ## Requirements

  The Rustler NIF must be compiled:

      # Ensure Rust toolchain is installed
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

      # Compile the NIF (happens automatically with mix compile if rustler is available)
      cd native/ex_maude_nif && cargo build --release

  """

  @behaviour ExMaude.Backend

  use GenServer
  require Logger

  alias ExMaude.{Binary, Error}

  @default_timeout 30_000

  @typedoc """
  Internal state for the NIF backend GenServer.
  """
  @type t :: %__MODULE__{
          handle: reference() | nil,
          maude_path: String.t() | nil,
          initialized: boolean()
        }

  defstruct [
    :handle,
    :maude_path,
    initialized: false
  ]

  # Native module - loads the Rustler NIF
  defmodule Native do
    @moduledoc false

    @on_load :load_nif

    @doc false
    @spec load_nif() :: :ok
    def load_nif do
      # Try to find the NIF in various locations
      nif_paths = [
        # Release build location
        Application.app_dir(:ex_maude, "priv/native/libex_maude_nif"),
        # Dev/test build location
        Path.join([File.cwd!(), "priv/native/libex_maude_nif"]),
        # Alternative naming without lib prefix
        Application.app_dir(:ex_maude, "priv/native/ex_maude_nif"),
        Path.join([File.cwd!(), "priv/native/ex_maude_nif"])
      ]

      result =
        Enum.find_value(nif_paths, :not_found, fn path ->
          case :erlang.load_nif(String.to_charlist(path), 0) do
            :ok -> :ok
            {:error, {:reload, _}} -> :ok
            {:error, {:upgrade, _}} -> :ok
            _ -> nil
          end
        end)

      case result do
        :ok -> :ok
        # NIF not found - this is expected when Rust NIF isn't compiled
        # Return :ok to prevent BEAM warnings (stubs will be used instead)
        :not_found -> :ok
      end
    end

    # NIF stubs - these are replaced at load time by the Rust implementations
    # If the NIF is not loaded, these return appropriate errors

    @doc false
    @spec start(String.t()) :: {:ok, reference()} | {:error, term()} | reference()
    def start(_maude_path) do
      :erlang.nif_error(:nif_not_loaded)
    end

    @doc false
    @spec execute(reference(), String.t()) :: binary() | {:ok, String.t()} | {:error, term()}
    def execute(_handle, _command) do
      :erlang.nif_error(:nif_not_loaded)
    end

    @doc false
    @spec stop(reference()) :: :ok | {:error, term()}
    def stop(_handle) do
      :erlang.nif_error(:nif_not_loaded)
    end

    @doc false
    @spec alive(reference()) :: boolean()
    def alive(_handle) do
      :erlang.nif_error(:nif_not_loaded)
    end
  end

  # Client API

  @impl ExMaude.Backend
  @doc """
  Starts the NIF backend worker.

  ## Options

    * `:maude_path` - Path to Maude executable (optional, auto-detected)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl ExMaude.Backend
  @doc """
  Executes a Maude command via NIF.

  ## Options

    * `:timeout` - Maximum time to wait in milliseconds (default: 30000)

  """
  @spec execute(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      GenServer.call(server, {:execute, command}, timeout + 1_000)
    catch
      :exit, {:timeout, _} -> {:error, Error.timeout(timeout)}
    end
  end

  @impl ExMaude.Backend
  @doc """
  Loads a Maude file via NIF.
  """
  @spec load_file(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def load_file(server, path) do
    GenServer.call(server, {:load_file, path}, @default_timeout)
  end

  @impl ExMaude.Backend
  @doc """
  Checks if the NIF backend is alive and initialized.
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    GenServer.call(server, :alive?)
  catch
    :exit, _ -> false
  end

  @impl ExMaude.Backend
  @doc """
  Stops the NIF backend worker.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # Server Callbacks
  # coveralls-ignore-start
  # GenServer callbacks require NIF to be loaded - tested via integration tests

  @impl GenServer
  def init(opts) do
    maude_path = opts[:maude_path] || Binary.find() || "maude"

    case start_native(maude_path) do
      {:ok, handle} ->
        emit_telemetry(:start, %{maude_path: maude_path})

        {:ok,
         %__MODULE__{
           handle: handle,
           maude_path: maude_path,
           initialized: true
         }}

      {:error, %Error{type: :nif_not_loaded} = _error} ->
        # Start in stub mode when NIF is not available
        Logger.debug("ExMaude.Backend.NIF starting in stub mode (NIF not loaded)")

        {:ok,
         %__MODULE__{
           handle: nil,
           maude_path: maude_path,
           initialized: false
         }}

      {:error, reason} ->
        {:stop, {:nif_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:execute, command}, _from, %{initialized: true, handle: handle} = state) do
    result =
      try do
        case Native.execute(handle, command) do
          result when is_binary(result) -> {:ok, result}
          {:ok, result} -> {:ok, result}
          {:error, _} = err -> err
        end
      rescue
        e ->
          {:error, Error.exception(:nif_error, Exception.message(e))}
      end

    emit_telemetry(:command_complete, %{success: match?({:ok, _}, result)})
    {:reply, result, state}
  end

  def handle_call({:execute, _command}, _from, state) do
    {:reply,
     {:error,
      Error.exception(
        :not_implemented,
        "NIF backend not yet implemented. Compile the Rustler NIF to enable."
      )}, state}
  end

  def handle_call({:load_file, path}, _from, %{initialized: true, handle: handle} = state) do
    command = "load #{path}"

    result =
      try do
        case Native.execute(handle, command) do
          result when is_binary(result) ->
            if String.contains?(result, "Error") do
              {:error, Error.exception(:load_error, result)}
            else
              :ok
            end

          {:ok, _} ->
            :ok

          {:error, _} = err ->
            err
        end
      rescue
        e ->
          {:error, Error.exception(:nif_error, Exception.message(e))}
      end

    {:reply, result, state}
  end

  def handle_call({:load_file, _path}, _from, state) do
    {:reply,
     {:error,
      Error.exception(
        :not_implemented,
        "NIF backend not yet implemented. Compile the Rustler NIF to enable."
      )}, state}
  end

  def handle_call(:alive?, _from, %{initialized: true, handle: handle} = state) do
    alive =
      try do
        Native.alive(handle)
      rescue
        _ -> false
      end

    {:reply, alive, state}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, false, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, %{handle: handle, initialized: true}) do
    Logger.debug("ExMaude.Backend.NIF terminating: #{inspect(reason)}")

    try do
      Native.stop(handle)
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(reason, _state) do
    Logger.debug("ExMaude.Backend.NIF terminating: #{inspect(reason)}")
    :ok
  end

  # coveralls-ignore-stop

  # Private Functions

  defp start_native(maude_path) do
    try do
      case Native.start(maude_path) do
        {:ok, _} = result -> result
        {:error, _} = err -> err
        handle when is_reference(handle) -> {:ok, handle}
      end
    rescue
      _e in UndefinedFunctionError ->
        {:error,
         Error.exception(
           :nif_not_loaded,
           "NIF not loaded. Ensure Rustler is installed and the NIF is compiled."
         )}

      e in ErlangError ->
        case Map.get(e, :original) do
          :nif_not_loaded ->
            {:error,
             Error.exception(
               :nif_not_loaded,
               "NIF not loaded. Ensure Rustler is installed and the NIF is compiled."
             )}

          other ->
            {:error, Error.exception(:nif_error, inspect(other))}
        end

      e ->
        {:error, Error.exception(:nif_error, Exception.message(e))}
    end
  end

  defp emit_telemetry(event, measurements) do
    :telemetry.execute(
      [:ex_maude, :server, event],
      Map.merge(measurements, %{time: System.system_time()}),
      %{pid: self(), backend: :nif}
    )
  end
end
