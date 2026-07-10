defmodule ExMaude.Backend.Port do
  @moduledoc """
  Port-based backend for ExMaude.

  This backend communicates with Maude via an Erlang Port over plain pipes,
  passing `-interactive` so Maude prints its prompt for response detection
  (the same mode the C-Node and NIF backends use).

  ## Features

    * Full process isolation - Maude crashes don't affect the BEAM
    * Works with any Maude installation
    * No native code compilation required

  ## Trade-offs

    * Port messaging and text parsing occur for every command
    * Regex-based error detection
    * Larger memory footprint per worker

  ## Configuration

      config :ex_maude,
        backend: :port,
        use_pty: false  # Set to true to wrap Maude in a PTY (script/unbuffer)

  ## Timeouts and worker lifecycle

  Each command carries its own timeout. When it fires, the caller receives
  `{:error, %ExMaude.Error{type: :timeout}}` and the worker **stops** with
  `{:shutdown, :command_timeout}` so the pool replaces it with a fresh
  process. Maude has no way to cancel an in-flight computation, so a
  timed-out session is in an indeterminate state — reusing it could deliver
  the previous command's response to the next caller.
  """

  @behaviour ExMaude.Backend

  use GenServer
  require Logger

  alias ExMaude.{Binary, Config, Error, Telemetry}

  @default_timeout_ms 5_000
  @startup_timeout_ms 10_000
  @prompt_marker "Maude>"
  @maude_args ["-no-banner", "-no-wrap", "-no-advise"]

  @typedoc """
  The in-flight command, if any.

  The `ref` ties the pending command to its `{:command_timeout, ref}` timer
  message: a timer that fires after its command completed carries a stale
  ref and is ignored instead of cutting into the next command.
  """
  @type pending :: %{
          from: GenServer.from(),
          ref: reference(),
          timer: reference(),
          timeout: pos_integer()
        }

  @typedoc """
  Internal state for the Port backend GenServer.
  """
  @type t :: %__MODULE__{
          port: port() | nil,
          buffer: String.t() | nil,
          pending: pending() | nil,
          maude_path: String.t() | nil,
          os_pid: non_neg_integer() | nil
        }

  defstruct [:port, :buffer, :pending, :maude_path, :os_pid]

  # Client API

  @impl ExMaude.Backend
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl ExMaude.Backend
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(@default_timeout_ms))

    try do
      GenServer.call(server, {:execute, command, timeout}, timeout + 1_000)
    catch
      :exit, {:timeout, _} ->
        {:error, Error.timeout(timeout)}

      :exit, {{:shutdown, reason}, _} ->
        # The worker stopped mid-call (e.g. it was checked out again in the
        # narrow window between a timeout reply and the pool reaping it).
        {:error, Error.pool_error({:worker_stopped, reason})}
    end
  end

  @impl ExMaude.Backend
  def load_file(server, path) do
    case execute(server, "load #{path}") do
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

  @impl GenServer
  def init(opts) do
    maude_path = opts[:maude_path] || find_maude_path()
    preload_modules = opts[:preload_modules] || config_preload_modules()
    startup_timeout = opts[:startup_timeout_ms] || @startup_timeout_ms

    case start_maude_port(maude_path, opts) do
      {:ok, port} ->
        state = %__MODULE__{
          port: port,
          buffer: "",
          pending: nil,
          maude_path: maude_path,
          os_pid: port_os_pid(port)
        }

        case become_ready(state, preload_modules, startup_timeout) do
          {:ok, state} ->
            emit_telemetry(:start, %{maude_path: maude_path})
            {:ok, state}

          {:error, reason} ->
            # init returning {:stop, _} skips terminate/2 — clean up inline.
            shutdown_maude(state)
            {:stop, {:maude_start_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:maude_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:execute, command, timeout}, from, %{pending: nil} = state) do
    command = ensure_command_format(command)
    Port.command(state.port, command)
    ref = make_ref()
    timer = Process.send_after(self(), {:command_timeout, ref}, timeout)

    emit_telemetry(:command_start, %{command: truncate(command, 100)})

    pending = %{from: from, ref: ref, timer: timer, timeout: timeout}
    {:noreply, %{state | pending: pending, buffer: ""}}
  end

  def handle_call({:execute, _, _}, _, state) do
    # Unreachable through the pool (a worker serves one checked-out caller at
    # a time) but a direct caller could race the in-flight command.
    {:reply, {:error, Error.new(:busy, "another command is already in flight")}, state}
  end

  def handle_call(:alive?, _, state) do
    alive = port_alive?(state.port)
    {:reply, alive, state}
  end

  # coveralls-ignore-start
  # Paths below require a live (or deliberately wedged) Maude process; they
  # are exercised by the fake-script lifecycle tests and integration tests.

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> to_string(data)

    if response_complete?(buffer) do
      response = parse_response(buffer)

      if state.pending do
        Process.cancel_timer(state.pending.timer)
        GenServer.reply(state.pending.from, response)
      end

      emit_telemetry(:command_complete, %{
        success: match?({:ok, _}, response),
        response_size: byte_size(buffer)
      })

      {:noreply, %{state | pending: nil, buffer: ""}}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Maude process exited with status #{status}")
    emit_telemetry(:crash, %{exit_status: status})

    if state.pending do
      GenServer.reply(state.pending.from, {:error, Error.crash(status)})
    end

    {:stop, {:maude_exit, status}, %{state | pending: nil}}
  end

  def handle_info({:command_timeout, ref}, %{pending: %{ref: ref} = pending} = state) do
    GenServer.reply(pending.from, {:error, Error.timeout(pending.timeout)})

    emit_telemetry(:timeout, %{
      buffer_size: byte_size(state.buffer),
      timeout_ms: pending.timeout
    })

    # Maude is still chewing on the timed-out command; its eventual output
    # would be misattributed to the next caller. Stop so the pool replaces
    # this worker with a fresh process. {:shutdown, _} keeps logs quiet.
    {:stop, {:shutdown, :command_timeout}, %{state | pending: nil}}
  end

  def handle_info({:command_timeout, _}, state) do
    # The timer fired after its command completed (cancel_timer lost the
    # race); the ref no longer matches the pending command, so drop it.
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("ExMaude.Backend.Port terminating: #{inspect(reason)}")
    shutdown_maude(state)
    :ok
  end

  # coveralls-ignore-stop

  # Private Functions
  # coveralls-ignore-start
  # These functions require an actual Maude process - tested via the
  # fake-script lifecycle tests and integration tests.

  defp shutdown_maude(state) do
    if state.port do
      try do
        if port_alive?(state.port) do
          Port.command(state.port, "quit\n")
          Process.sleep(100)
          Port.close(state.port)
        end
      rescue
        ArgumentError -> :ok
      end
    end

    kill_os_process(state.os_pid)
  end

  # A wedged Maude (e.g. mid-infinite-rewrite) never reads the `quit`, and
  # Port.close/1 does not signal the OS process — without this a timed-out
  # command would leak a CPU-pegged interpreter. In PTY mode the pid is the
  # wrapper's; killing it tears down its PTY and Maude with it.
  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp start_maude_port(maude_path, opts) do
    maude_executable = find_executable(maude_path)
    use_pty = Keyword.get(opts, :use_pty, Application.get_env(:ex_maude, :use_pty, false))

    {wrapper_executable, wrapper_args} =
      resolve_launcher(use_pty, :os.type(), maude_executable)

    try do
      port =
        Port.open(
          {:spawn_executable, wrapper_executable},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, wrapper_args},
            :stream
          ]
        )

      {:ok, port}
    rescue
      e -> {:error, e}
    end
  end

  # coveralls-ignore-stop

  @doc false
  # Maude only prints its `Maude>` prompt when it believes it is interactive:
  # either stdin is a TTY (PTY wrapper) or `-interactive` forces it. Every
  # branch must produce one of the two — a launcher with neither yields a
  # worker whose commands can never complete.
  #
  # PTY wrappers: macOS `script -q`, Linux `unbuffer` (expect) or `script -qc`.
  # When no wrapper exists (minimal containers), fall back to plain pipes
  # with `-interactive`, the same mode the NIF and C-Node backends use.
  @spec resolve_launcher(boolean(), {atom(), atom()}, String.t(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()]}
  def resolve_launcher(use_pty?, os_type, executable, finder \\ &System.find_executable/1)

  def resolve_launcher(false, _, executable, _) do
    {executable, ["-interactive" | @maude_args]}
  end

  def resolve_launcher(true, {:unix, :darwin}, executable, finder) do
    case finder.("script") do
      nil -> {executable, ["-interactive" | @maude_args]}
      script_path -> {script_path, ["-q", "/dev/null", executable | @maude_args]}
    end
  end

  def resolve_launcher(true, {:unix, _}, executable, finder) do
    # Linux: prefer `unbuffer` (from expect); fall back to `script -qc`
    # whose syntax differs from macOS.
    cond do
      unbuffer = finder.("unbuffer") ->
        {unbuffer, [executable | @maude_args]}

      script = finder.("script") ->
        cmd = Enum.join([executable | @maude_args], " ")
        {script, ["-qc", cmd, "/dev/null"]}

      true ->
        {executable, ["-interactive" | @maude_args]}
    end
  end

  def resolve_launcher(true, _, executable, _) do
    {executable, ["-interactive" | @maude_args]}
  end

  # coveralls-ignore-start

  defp find_executable(path) do
    case System.find_executable(path) do
      nil -> raise "Maude executable not found at #{path}"
      found -> found
    end
  end

  defp find_maude_path do
    Binary.find() || "maude"
  end

  defp become_ready(state, preload, startup_timeout) do
    with {:ok, state} <- wait_for_ready(state, startup_timeout) do
      preload_modules(state, preload, startup_timeout)
    end
  end

  defp wait_for_ready(state, startup_timeout) do
    receive do
      {port, {:data, data}} when port == state.port ->
        buffer = state.buffer <> to_string(data)

        if String.contains?(buffer, @prompt_marker) do
          {:ok, %{state | buffer: ""}}
        else
          wait_for_ready(%{state | buffer: buffer}, startup_timeout)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error, {:exited_during_startup, status}}
    after
      startup_timeout ->
        Logger.error("Timeout waiting for Maude prompt (#{startup_timeout}ms)")
        {:error, :no_prompt}
    end
  end

  defp preload_modules(state, [], _), do: {:ok, state}

  defp preload_modules(state, [path | rest], startup_timeout) do
    if File.exists?(path) do
      Port.command(state.port, "load #{path}\n")

      case wait_for_ready(state, startup_timeout) do
        {:ok, state} -> preload_modules(state, rest, startup_timeout)
        {:error, reason} -> {:error, {:preload_failed, path, reason}}
      end
    else
      Logger.warning("Preload module not found: #{path}")
      preload_modules(state, rest, startup_timeout)
    end
  end

  defp ensure_command_format(command) do
    command = String.trim(command)

    command =
      if String.ends_with?(command, ".") do
        command
      else
        command <> " ."
      end

    command <> "\n"
  end

  defp response_complete?(buffer), do: String.contains?(buffer, @prompt_marker)

  defp parse_response(buffer) do
    buffer
    |> String.split(@prompt_marker)
    |> List.first()
    |> ExMaude.Parser.parse_backend_response()
  end

  defp port_alive?(port), do: Port.info(port) != nil

  defp config_preload_modules do
    Application.get_env(:ex_maude, :preload_modules, [])
  end

  defp truncate(string, max_length) when byte_size(string) > max_length do
    String.slice(string, 0, max_length) <> "..."
  end

  defp truncate(string, _), do: string

  defp emit_telemetry(event, measurements) do
    Telemetry.server_event(event, measurements, %{pid: self(), backend: :port})
  end

  # coveralls-ignore-stop
end
