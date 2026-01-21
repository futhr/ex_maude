defmodule ExMaude.Backend.Port do
  @moduledoc """
  Port-based backend for ExMaude.

  This backend communicates with Maude via an Erlang Port, using a PTY wrapper
  to ensure Maude outputs prompts for response detection.

  ## Features

    * Full process isolation - Maude crashes don't affect the BEAM
    * Works with any Maude installation
    * No native code compilation required

  ## Trade-offs

    * Higher latency due to PTY wrapper and text parsing
    * Regex-based error detection
    * Larger memory footprint per worker

  ## Configuration

      config :ex_maude,
        backend: :port,
        use_pty: true  # Set to false if PTY allocation fails

  """

  @behaviour ExMaude.Backend

  use GenServer
  require Logger

  alias ExMaude.{Binary, Error}

  @default_timeout_ms 5_000
  @prompt_marker "Maude>"

  @typedoc """
  Internal state for the Port backend GenServer.
  """
  @type t :: %__MODULE__{
          port: port() | nil,
          buffer: String.t() | nil,
          from: GenServer.from() | nil,
          timeout_ref: reference() | nil,
          maude_path: String.t() | nil
        }

  defstruct [:port, :buffer, :from, :timeout_ref, :maude_path]

  # Client API

  @impl ExMaude.Backend
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl ExMaude.Backend
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    try do
      GenServer.call(server, {:execute, command, timeout}, timeout + 1_000)
    catch
      :exit, {:timeout, _} -> {:error, Error.timeout(timeout)}
    end
  end

  @impl ExMaude.Backend
  def load_file(server, path) do
    case execute(server, "load #{path}") do
      {:ok, _output} -> :ok
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
  # GenServer callbacks require actual Maude process - tested via integration tests

  @impl GenServer
  def init(opts) do
    maude_path = opts[:maude_path] || find_maude_path()
    preload_modules = opts[:preload_modules] || config_preload_modules()

    case start_maude_port(maude_path) do
      {:ok, port} ->
        state = %__MODULE__{
          port: port,
          buffer: "",
          from: nil,
          timeout_ref: nil,
          maude_path: maude_path
        }

        # Wait for initial banner/prompt
        state = wait_for_ready(state)

        # Preload configured modules
        state = preload_modules(state, preload_modules)

        emit_telemetry(:start, %{maude_path: maude_path})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:maude_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:execute, command, timeout}, from, state) do
    # Ensure command ends with period and newline
    command = ensure_command_format(command)

    # Send command to Maude
    Port.command(state.port, command)

    # Set timeout
    timeout_ref = Process.send_after(self(), :command_timeout, timeout)

    emit_telemetry(:command_start, %{command: truncate(command, 100)})

    {:noreply, %{state | from: from, buffer: "", timeout_ref: timeout_ref}}
  end

  def handle_call(:alive?, _from, state) do
    alive = port_alive?(state.port)
    {:reply, alive, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> to_string(data)

    if response_complete?(buffer) do
      # Cancel timeout
      if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

      # Parse and send response
      response = parse_response(buffer)

      if state.from do
        GenServer.reply(state.from, response)
      end

      emit_telemetry(:command_complete, %{
        success: match?({:ok, _}, response),
        response_size: byte_size(buffer)
      })

      {:noreply, %{state | from: nil, buffer: "", timeout_ref: nil}}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Maude process exited with status #{status}")
    emit_telemetry(:crash, %{exit_status: status})

    if state.from do
      GenServer.reply(state.from, {:error, Error.crash(status)})
    end

    {:stop, {:maude_exit, status}, state}
  end

  def handle_info(:command_timeout, state) do
    if state.from do
      GenServer.reply(state.from, {:error, Error.timeout(@default_timeout_ms)})
    end

    emit_telemetry(:timeout, %{buffer_size: byte_size(state.buffer)})

    {:noreply, %{state | from: nil, buffer: "", timeout_ref: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("ExMaude.Backend.Port terminating: #{inspect(reason)}")

    if state.port do
      try do
        if port_alive?(state.port) do
          # Try graceful shutdown
          Port.command(state.port, "quit\n")
          Process.sleep(100)
          Port.close(state.port)
        end
      rescue
        ArgumentError ->
          # Port was already closed, nothing to do
          :ok
      end
    end

    :ok
  end

  # coveralls-ignore-stop

  # Private Functions
  # coveralls-ignore-start
  # These functions require actual Maude process - tested via integration tests

  defp start_maude_port(maude_path) do
    maude_executable = find_executable(maude_path)
    use_pty = Application.get_env(:ex_maude, :use_pty, true)

    # Base args - suppress banner, line wrapping, and advisories
    maude_args = ["-no-banner", "-no-wrap", "-no-advise"]

    # When not using PTY, add -interactive to force prompt output
    maude_args =
      if use_pty do
        maude_args
      else
        ["-interactive" | maude_args]
      end

    # Use script/unbuffer to create a PTY so Maude outputs prompts
    # Can be disabled via config if PTY allocation fails (e.g., in Docker/CI)
    {wrapper_executable, wrapper_args} =
      if use_pty do
        pty_wrapper(maude_executable, maude_args)
      else
        {maude_executable, maude_args}
      end

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

  # Use a PTY wrapper to make Maude think it's running interactively
  # This is needed because Maude only outputs prompts in TTY mode
  defp pty_wrapper(executable, args) do
    case :os.type() do
      {:unix, :darwin} ->
        # macOS: use script -q /dev/null
        script_path = System.find_executable("script")

        if script_path do
          # script -q /dev/null maude args...
          {script_path, ["-q", "/dev/null", executable | args]}
        else
          {executable, args}
        end

      {:unix, _} ->
        # Linux: try unbuffer first, then script
        cond do
          unbuffer = System.find_executable("unbuffer") ->
            {unbuffer, [executable | args]}

          script = System.find_executable("script") ->
            # Linux script syntax differs: script -qc "command" /dev/null
            cmd = Enum.join([executable | args], " ")
            {script, ["-qc", cmd, "/dev/null"]}

          true ->
            {executable, args}
        end

      _ ->
        {executable, args}
    end
  end

  defp find_executable(path) do
    case System.find_executable(path) do
      nil -> raise "Maude executable not found at #{path}"
      found -> found
    end
  end

  defp find_maude_path do
    # Delegate to ExMaude.Binary for centralized binary management
    Binary.find() || "maude"
  end

  defp wait_for_ready(state) do
    # Collect initial output until we see the prompt
    receive do
      {port, {:data, data}} when port == state.port ->
        buffer = state.buffer <> to_string(data)

        if String.contains?(buffer, @prompt_marker) do
          %{state | buffer: ""}
        else
          wait_for_ready(%{state | buffer: buffer})
        end
    after
      10_000 ->
        Logger.error("Timeout waiting for Maude to start")
        state
    end
  end

  defp preload_modules(state, []), do: state

  defp preload_modules(state, [path | rest]) do
    if File.exists?(path) do
      Port.command(state.port, "load #{path}\n")
      state = wait_for_ready(state)
      preload_modules(state, rest)
    else
      Logger.warning("Preload module not found: #{path}")
      preload_modules(state, rest)
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

  defp response_complete?(buffer) do
    # Response is complete when we see the prompt
    String.contains?(buffer, @prompt_marker)
  end

  defp parse_response(buffer) do
    # Remove the prompt from the end
    output =
      buffer
      |> String.split(@prompt_marker)
      |> List.first()
      |> String.trim()

    # Check for errors - but be more careful about false positives
    cond do
      has_maude_error?(output) ->
        {:error, Error.from_output(output)}

      String.contains?(output, "result") ->
        # Extract result value
        result = extract_result(output)
        {:ok, result}

      true ->
        {:ok, output}
    end
  end

  # Check if output contains actual Maude errors (not just the word "error" in content)
  defp has_maude_error?(output) do
    # Look for Maude error patterns
    error_patterns = [
      ~r/Error:/,
      ~r/Warning:/,
      ~r/No parse for term/,
      ~r/no module\s+\S+/i,
      ~r/module\s+\S+\s+not found/i,
      ~r/syntax error/i,
      ~r/Advisory:/
    ]

    Enum.any?(error_patterns, fn pattern ->
      Regex.match?(pattern, output)
    end)
  end

  defp extract_result(output) do
    # Parse "result Type: value" format
    case Regex.run(~r/result\s+\w+:\s*(.+)/s, output) do
      [_, value] -> String.trim(value)
      nil -> output
    end
  end

  defp port_alive?(port) do
    case Port.info(port) do
      nil -> false
      _ -> true
    end
  end

  defp config_preload_modules do
    Application.get_env(:ex_maude, :preload_modules, [])
  end

  defp truncate(string, max_length) when byte_size(string) > max_length do
    String.slice(string, 0, max_length) <> "..."
  end

  defp truncate(string, _max_length), do: string

  defp emit_telemetry(event, measurements) do
    :telemetry.execute(
      [:ex_maude, :server, event],
      Map.merge(measurements, %{time: System.system_time()}),
      %{pid: self(), backend: :port}
    )
  end

  # coveralls-ignore-stop
end
