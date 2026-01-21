defmodule ExMaude.Backend.CNode do
  @moduledoc """
  C-Node backend for ExMaude.

  This backend communicates with Maude via a C-Node bridge process that uses
  Erlang distribution protocol for structured binary communication.

  ## Features

    * Full process isolation - C-Node crash doesn't affect the BEAM
    * Binary Erlang term protocol - no text parsing overhead
    * Lower latency than Port + PTY wrapper

  ## Trade-offs

    * Requires compiled C code (maude_bridge binary)
    * More complex deployment (native dependency)
    * Requires Erlang distribution (epmd must be running)

  ## Requirements

  The C-Node bridge binary must be compiled:

      cd c_src && make

  Or it will be compiled automatically if `elixir_make` is configured.

  ## Configuration

      config :ex_maude,
        backend: :cnode,
        cnode_timeout: 30_000

  """

  @behaviour ExMaude.Backend

  use GenServer
  require Logger

  alias ExMaude.{Binary, Error}

  @default_timeout 30_000
  @connect_timeout 10_000
  @health_check_interval 5_000

  @typedoc """
  Internal state for the C-Node backend GenServer.
  """
  @type t :: %__MODULE__{
          cnode_name: atom() | nil,
          port: port() | nil,
          os_pid: non_neg_integer() | nil,
          maude_path: String.t() | nil,
          cookie: String.t(),
          connected: boolean()
        }

  defstruct [
    :cnode_name,
    :port,
    :os_pid,
    :maude_path,
    cookie: "",
    connected: false
  ]

  # Client API

  @impl ExMaude.Backend
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl ExMaude.Backend
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      GenServer.call(server, {:execute, command}, timeout + 1_000)
    catch
      :exit, {:timeout, _} -> {:error, Error.timeout(timeout)}
    end
  end

  @impl ExMaude.Backend
  def load_file(server, path) do
    case GenServer.call(server, {:load_file, path}, @default_timeout) do
      :ok -> :ok
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl ExMaude.Backend
  def alive?(server) do
    GenServer.call(server, :alive?)
  catch
    :exit, _ -> false
  end

  @impl ExMaude.Backend
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # Server Callbacks
  # coveralls-ignore-start
  # GenServer callbacks require C-Node binary and distributed node - tested via integration tests

  @impl GenServer
  def init(opts) do
    maude_path = opts[:maude_path] || Binary.find() || "maude"
    cookie = opts[:cookie] || get_cookie()

    state = %__MODULE__{
      maude_path: maude_path,
      cookie: cookie
    }

    case start_cnode(state) do
      {:ok, state} ->
        schedule_health_check()
        emit_telemetry(:start, %{maude_path: maude_path})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:cnode_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:execute, command}, _from, %{connected: true} = state) do
    result = send_cnode_command(state.cnode_name, {:execute, command})
    emit_telemetry(:command_complete, %{success: match?({:ok, _}, result)})
    {:reply, result, state}
  end

  def handle_call({:execute, _command}, _from, %{connected: false} = state) do
    {:reply, {:error, Error.exception(:not_connected, "C-Node not connected")}, state}
  end

  def handle_call({:load_file, path}, _from, %{connected: true} = state) do
    result = send_cnode_command(state.cnode_name, {:load_file, path})
    {:reply, result, state}
  end

  def handle_call({:load_file, _path}, _from, %{connected: false} = state) do
    {:reply, {:error, Error.exception(:not_connected, "C-Node not connected")}, state}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    case send_cnode_command(state.cnode_name, :ping) do
      :pong ->
        schedule_health_check()
        {:noreply, %{state | connected: true}}

      _ ->
        Logger.warning("C-Node health check failed")
        {:noreply, %{state | connected: false}}
    end
  end

  def handle_info({:nodedown, node}, %{cnode_name: node} = state) do
    Logger.error("C-Node #{node} went down")
    emit_telemetry(:crash, %{node: node})
    {:stop, :nodedown, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    output = to_string(data)
    Logger.debug("C-Node output: #{String.trim(output)}")

    # Check if the output contains READY signal (may be mixed with other output)
    if String.contains?(output, "READY") and not state.connected do
      Logger.info("C-Node ready, connecting...")

      case connect_to_cnode(state) do
        {:ok, state} ->
          {:noreply, state}

        {:error, reason} ->
          Logger.error("Failed to connect to C-Node: #{inspect(reason)}")
          {:stop, {:connect_failed, reason}, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("C-Node process exited with status #{status}")
    emit_telemetry(:crash, %{exit_status: status})
    {:stop, {:cnode_exit, status}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("ExMaude.Backend.CNode terminating: #{inspect(reason)}")

    # Send stop command to C-Node
    if state.connected do
      send_cnode_command(state.cnode_name, :stop)
    end

    # Close the port
    if state.port do
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # coveralls-ignore-stop

  # Private Functions
  # coveralls-ignore-start
  # These functions require C-Node binary and distributed node - tested via integration tests

  defp start_cnode(state) do
    bridge_path = bridge_executable()

    unless File.exists?(bridge_path) do
      {:error, {:missing_binary, bridge_path}}
    else
      # Generate both string (for args) and atom (for cnode_name) forms
      {node_name_str, cnode_name_atom} = generate_node_name()
      erlang_node = Atom.to_string(Node.self())

      # Ensure we're running as a distributed node
      unless Node.alive?() do
        {:error, :node_not_distributed}
      else
        args = [
          node_name_str,
          state.cookie,
          state.maude_path,
          erlang_node
        ]

        port =
          Port.open(
            {:spawn_executable, bridge_path},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, args},
              :stream
            ]
          )

        {:os_pid, os_pid} = Port.info(port, :os_pid)

        {:ok,
         %{
           state
           | port: port,
             os_pid: os_pid,
             cnode_name: cnode_name_atom
         }}
      end
    end
  end

  defp connect_to_cnode(state, retries \\ 10) do
    if retries <= 0 do
      Logger.error("Failed to connect to C-Node after all retries: #{state.cnode_name}")
      {:error, :connect_exhausted}
    else
      Process.sleep(500)

      case Node.connect(state.cnode_name) do
        true ->
          Node.monitor(state.cnode_name, true)
          Logger.info("Connected to C-Node: #{state.cnode_name}")
          {:ok, %{state | connected: true}}

        false ->
          Logger.warning(
            "Connect attempt to #{state.cnode_name} failed, #{retries - 1} retries left"
          )

          connect_to_cnode(state, retries - 1)
      end
    end
  end

  defp send_cnode_command(cnode_name, command) do
    try do
      # Send command to C-Node using the :any registered name pattern
      # The C-Node expects: {:execute, binary} or atoms like :ping, :stop
      send({:any, cnode_name}, command)

      receive do
        response -> response
      after
        @connect_timeout ->
          {:error, Error.timeout(@connect_timeout)}
      end
    catch
      kind, reason ->
        Logger.error("C-Node command failed: #{kind} - #{inspect(reason)}")
        {:error, Error.exception(:cnode_error, inspect(reason))}
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp bridge_executable do
    priv_dir = Binary.priv_dir()
    Path.join(priv_dir, "maude_bridge")
  end

  defp get_cookie do
    case Node.get_cookie() do
      :nocookie -> "exmaude"
      cookie -> Atom.to_string(cookie)
    end
  end

  @doc false
  # sobelow_skip ["DOS.BinToAtom"]
  defp generate_node_name do
    # id is always a positive integer from :erlang.unique_integer - safe for atom creation
    id = :erlang.unique_integer([:positive])
    node_str = "maude_bridge_#{id}"
    # Extract hostname from current node (e.g., test@studio -> studio)
    hostname = Node.self() |> Atom.to_string() |> String.split("@") |> List.last()
    node_atom = :"maude_bridge_#{id}@#{hostname}"
    {node_str, node_atom}
  end

  defp emit_telemetry(event, measurements) do
    :telemetry.execute(
      [:ex_maude, :server, event],
      Map.merge(measurements, %{time: System.system_time()}),
      %{pid: self(), backend: :cnode}
    )
  end

  # coveralls-ignore-stop
end
