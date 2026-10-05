defmodule ExMaude.Subprocess do
  @moduledoc false

  @doc false
  @spec run(Path.t(), [String.t()], pos_integer(), pos_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run(executable, args, timeout, max_bytes),
    do: run(executable, args, timeout, max_bytes, :none)

  @doc false
  @spec run(Path.t(), [String.t()], pos_integer(), pos_integer(), integer() | :none) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run(executable, args, timeout, max_bytes, enclosing_deadline)
      when enclosing_deadline == :none or is_integer(enclosing_deadline) do
    cap = System.monotonic_time(:millisecond) + timeout
    deadline = if enclosing_deadline == :none, do: cap, else: min(cap, enclosing_deadline)
    owner = self()
    reply = make_ref()

    {collector, monitor} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(owner)

        result =
          if Process.alive?(owner),
            do: run_owned(executable, args, deadline, max_bytes, owner_ref),
            else: {:error, :owner_lost}

        Process.demonitor(owner_ref, [:flush])
        send(owner, {reply, self(), result})
      end)

    receive do
      {^reply, ^collector, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^collector, reason} ->
        {:error, {:collector_exit, reason}}
    end
  end

  def run(_, _, _, _, _), do: {:error, :invalid_deadline}

  defp run_owned(executable, args, deadline, max_bytes, owner_ref) do
    if deadline > System.monotonic_time(:millisecond),
      do: collect_owned(executable, args, deadline, max_bytes, owner_ref),
      else: {:error, :timeout}
  end

  defp collect_owned(executable, args, deadline, max_bytes, owner_ref) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: args
      ])

    try do
      ownership = {deadline, owner_ref}
      collect(port, ownership, max_bytes, [], 0)
    after
      stop(port)
    end
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp collect(port, {deadline, owner_ref} = ownership, limit, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= limit ->
        collect(port, ownership, limit, [data | chunks], size + byte_size(data))

      {^port, {:data, _}} ->
        {:error, :output_too_large}

      {^port, {:exit_status, status}} ->
        output =
          chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:ok, output, status}

      {:DOWN, ^owner_ref, :process, _, _} ->
        {:error, :owner_lost}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        Port.close(port)

        case :os.type() do
          {:win32, _} -> System.cmd("taskkill", ["/F", "/PID", Integer.to_string(pid)])
          _ -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
