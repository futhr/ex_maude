defmodule ExMaude.Backend.CNode do
  @moduledoc """
  C-Node backend for ExMaude.

  This backend communicates with Maude via a C-Node bridge process that uses
  Erlang distribution protocol for structured binary communication.

  ## Features

    * Full process isolation - C-Node crash doesn't affect the BEAM
    * Binary Erlang term protocol - no Erlang Port framing overhead
    * Lower latency than the Port backend

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

  alias ExMaude.{Binary, Error, Parser}

  @default_timeout 30_000
  @ping_timeout 2_000
  @health_check_interval 5_000
  @connect_retries 10
  @connect_retry_delay 500
  @node_name_slots 1_024
  # Grace period on top of the command timeout for the bridge's own
  # timeout reply ({Ref, {:error, :read_failed}}) to arrive before we
  # give up on the receive.
  @reply_grace 500

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
    startup_timeout = Keyword.get(opts, :startup_timeout_ms, @default_timeout)
    preload_modules = Keyword.get(opts, :preload_modules, config_preload_modules())

    case GenServer.start_link(__MODULE__, opts) do
      {:ok, server} ->
        result =
          with :ok <- await_connection(server, startup_timeout),
               :ok <- preload_modules(server, preload_modules) do
            :ok
          end

        case result do
          :ok ->
            {:ok, server}

          {:error, _} = error ->
            safe_stop(server)
            error
        end

      other ->
        other
    end
  end

  @impl ExMaude.Backend
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      GenServer.call(server, {:execute, command, timeout}, timeout + 1_000)
    catch
      :exit, {:timeout, _} ->
        {:error, Error.timeout(timeout)}

      :exit, {{:shutdown, reason}, _} ->
        # The worker stopped mid-call (e.g. it was checked out again in the
        # narrow window between a failure reply and the pool reaping it).
        {:error, Error.pool_error({:worker_stopped, reason})}
    end
  end

  @impl ExMaude.Backend
  def load_file(server, path) do
    case GenServer.call(server, {:load_file, path, @default_timeout}, @default_timeout + 1_000) do
      :ok -> :ok
      {:ok, _} -> :ok
      error -> error
    end
  catch
    :exit, {:timeout, _} ->
      {:error, Error.timeout(@default_timeout)}

    :exit, {{:shutdown, reason}, _} ->
      {:error, Error.pool_error({:worker_stopped, reason})}
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
  def handle_call({:execute, command, timeout}, _, %{connected: true} = state) do
    case send_cnode_command(state.cnode_name, {:execute, normalize_command(command)}, timeout) do
      {:ok, raw} ->
        result = Parser.parse_backend_response(raw)
        emit_telemetry(:command_complete, %{success: match?({:ok, _}, result)})
        {:reply, result, state}

      {:error, %Error{} = err} ->
        stop_on_bridge_failure(err, state)

      other ->
        {:reply, {:error, Error.exception(:cnode_error, inspect(other))}, state}
    end
  end

  def handle_call({:execute, _, _}, _, %{connected: false} = state) do
    {:reply, {:error, Error.exception(:not_connected, "C-Node not connected")}, state}
  end

  def handle_call({:load_file, path, timeout}, _, %{connected: true} = state) do
    case send_cnode_command(state.cnode_name, {:load_file, path}, timeout) do
      :ok ->
        {:reply, :ok, state}

      {:ok, _} ->
        {:reply, :ok, state}

      {:error, output} when is_binary(output) ->
        # Semantic load failure (Maude warning/error text) — the session is
        # still healthy, keep the worker.
        {:reply, {:error, Error.from_output(output)}, state}

      {:error, %Error{} = err} ->
        stop_on_bridge_failure(err, state)
    end
  end

  def handle_call({:load_file, _, _}, _, %{connected: false} = state) do
    {:reply, {:error, Error.exception(:not_connected, "C-Node not connected")}, state}
  end

  def handle_call(:alive?, _, state) do
    {:reply, state.connected, state}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    case send_cnode_command(state.cnode_name, :ping, @ping_timeout) do
      :pong ->
        schedule_health_check()
        {:noreply, %{state | connected: true}}

      other ->
        # A bridge that stops answering pings is gone for good as far as
        # this worker is concerned — stop so the pool starts a fresh one
        # instead of serving :not_connected forever.
        Logger.warning("C-Node health check failed: #{inspect(other)}")
        emit_telemetry(:crash, %{reason: :health_check_failed})
        {:stop, {:shutdown, :health_check_failed}, state}
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

    # The READY signal may be mixed with other startup output. The bridge
    # prints it after its own ei_connect to this node succeeded, so the
    # first connect attempt normally succeeds immediately.
    if String.contains?(output, "READY") and not state.connected do
      Logger.info("C-Node ready, connecting...")
      handle_info({:connect_retry, @connect_retries}, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:connect_retry, 0}, state) do
    Logger.error("Failed to connect to C-Node after all retries: #{state.cnode_name}")
    {:stop, {:connect_failed, :retries_exhausted}, state}
  end

  def handle_info({:connect_retry, retries_left}, %{connected: false} = state) do
    if Node.connect(state.cnode_name) do
      Node.monitor(state.cnode_name, true)
      Logger.info("Connected to C-Node: #{state.cnode_name}")
      {:noreply, %{state | connected: true}}
    else
      Logger.warning(
        "Connect attempt to #{state.cnode_name} failed, #{retries_left - 1} retries left"
      )

      Process.send_after(self(), {:connect_retry, retries_left - 1}, @connect_retry_delay)
      {:noreply, state}
    end
  end

  def handle_info({:connect_retry, _}, state) do
    # Already connected — a stale retry message.
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("C-Node process exited with status #{status}")
    emit_telemetry(:crash, %{exit_status: status})
    {:stop, {:cnode_exit, status}, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("ExMaude.Backend.CNode terminating: #{inspect(reason)}")

    # Fire-and-forget: when the bridge's message loop next wakes up (at
    # latest after an in-flight read times out) it exits its loop and
    # tears Maude down with it.
    if state.connected do
      send({:any, state.cnode_name}, :stop)
    end

    if state.port do
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      end
    end

    # SIGTERM (not KILL) as a prompt backstop: the bridge traps it, exits
    # its loop, and stop_maude() reaps the Maude child. SIGKILL would
    # orphan a possibly CPU-pegged Maude.
    if state.os_pid do
      System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  # coveralls-ignore-stop

  # Private Functions
  # coveralls-ignore-start
  # These functions require C-Node binary and distributed node - tested via integration tests

  defp start_cnode(state) do
    bridge_path = bridge_executable()

    cond do
      not File.exists?(bridge_path) ->
        {:error, {:missing_binary, bridge_path}}

      not Node.alive?() ->
        {:error, :node_not_distributed}

      true ->
        # Generate both string (for args) and atom (for cnode_name) forms
        {node_name_str, cnode_name_atom} = generate_node_name()
        erlang_node = Atom.to_string(Node.self())

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

  # A timeout or bridge-level failure leaves the bridge's Maude session in
  # an indeterminate state — Maude cannot cancel an in-flight computation,
  # and its eventual output would be misattributed to the next caller.
  # Reply, then stop so the pool starts a fresh bridge + Maude pair.
  defp stop_on_bridge_failure(%Error{} = err, state) do
    if err.type == :timeout do
      emit_telemetry(:timeout, %{timeout_ms: err.details.timeout_ms})
    end

    emit_telemetry(:command_complete, %{success: false})
    {:stop, {:shutdown, {:bridge_failure, err.type}}, {:error, err}, state}
  end

  # Sends a ref-tagged request and selectively receives the matching
  # {ref, reply}. Stale replies from previously timed-out commands carry a
  # different ref, are never matched here, and drain through the GenServer's
  # handle_info catch-all instead of being misattributed.
  defp send_cnode_command(cnode_name, request, timeout) do
    ref = make_ref()

    try do
      send({:any, cnode_name}, build_request(request, ref, timeout))

      receive do
        {^ref, response} -> normalize_response(response, timeout)
      after
        timeout + @reply_grace ->
          {:error, Error.timeout(timeout)}
      end
    catch
      kind, reason ->
        Logger.error("C-Node command failed: #{kind} - #{inspect(reason)}")
        {:error, Error.exception(:cnode_error, inspect(reason))}
    end
  end

  defp build_request({:execute, command}, ref, timeout), do: {:execute, ref, command, timeout}
  defp build_request({:load_file, path}, ref, timeout), do: {:load_file, ref, path, timeout}
  defp build_request(:ping, ref, _), do: {:ping, ref}

  # Bridge replies: {:ok, output} / :ok / :pong pass through; atom error
  # reasons are infrastructure failures (:read_timeout maps to the caller's
  # command deadline, :maude_eof to a crashed interpreter); binary error
  # payloads are semantic Maude output and keep their shape for the caller
  # to interpret.
  defp normalize_response({:ok, output}, _), do: {:ok, output}
  defp normalize_response(:ok, _), do: :ok
  defp normalize_response(:pong, _), do: :pong

  defp normalize_response({:error, :read_timeout}, timeout),
    do: {:error, Error.timeout(timeout)}

  defp normalize_response({:error, :maude_eof}, _),
    do: {:error, Error.crash(0)}

  defp normalize_response({:error, reason}, _) when is_atom(reason),
    do: {:error, Error.exception(:cnode_error, "bridge failure: #{reason}")}

  defp normalize_response({:error, output}, _) when is_binary(output),
    do: {:error, output}

  defp normalize_response(other, _),
    do: {:error, Error.exception(:cnode_error, "unexpected bridge reply: #{inspect(other)}")}

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
    # Distribution node names are atoms. Reuse a bounded set of slots so
    # worker restarts cannot grow the VM's atom table without limit.
    id = rem(:erlang.unique_integer([:positive]), @node_name_slots)
    node_str = "maude_bridge_#{id}"
    # Extract hostname from current node (e.g., test@studio -> studio)
    hostname =
      Node.self()
      |> Atom.to_string()
      |> String.split("@")
      |> List.last()

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    node_atom = :"maude_bridge_#{id}@#{hostname}"
    {node_str, node_atom}
  end

  defp await_connection(server, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_connection_until(server, deadline)
  end

  defp await_connection_until(server, deadline) do
    cond do
      alive?(server) ->
        :ok

      not Process.alive?(server) ->
        {:error, :cnode_start_failed}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :cnode_connection_timeout}

      true ->
        Process.sleep(25)
        await_connection_until(server, deadline)
    end
  end

  defp preload_modules(_server, []), do: :ok

  defp preload_modules(server, [path | paths]) do
    case load_file(server, path) do
      :ok -> preload_modules(server, paths)
      {:error, reason} -> {:error, {:preload_failed, path, reason}}
    end
  end

  defp safe_stop(server) do
    if Process.alive?(server), do: GenServer.stop(server, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp normalize_command(command) do
    command = String.trim_trailing(command)
    if String.ends_with?(command, "."), do: command, else: command <> " ."
  end

  defp config_preload_modules do
    Application.get_env(:ex_maude, :preload_modules, [])
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
