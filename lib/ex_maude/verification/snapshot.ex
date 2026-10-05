defmodule ExMaude.Verification.Snapshot do
  @moduledoc false
  use GenServer
  alias ExMaude.Error
  @maximum_bytes 16_777_216

  @doc false
  @spec start(binary()) :: {:ok, pid(), Path.t()} | {:error, Error.t()}
  def start(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum_bytes do
    case GenServer.start(__MODULE__, {self(), bytes}) do
      {:ok, lease} ->
        {:ok, path} = GenServer.call(lease, :path)
        {:ok, lease, path}

      {:error, %Error{}} = error ->
        error

      other ->
        {:error, Error.new(:load_error, "snapshot initialization failed: #{inspect(other)}")}
    end
  end

  def start(_), do: {:error, Error.new(:validation, "snapshot requires bounded nonempty bytes")}

  @doc false
  @spec close(pid()) :: :ok | {:error, Error.t()}
  def close(lease) do
    GenServer.call(lease, :close)
  catch
    :exit, _ -> {:error, Error.new(:validation, "snapshot lease has ended")}
  end

  @impl GenServer
  def init({owner, bytes}) do
    monitor = Process.monitor(owner)

    directory =
      Path.join(
        System.tmp_dir!(),
        "ex_maude_search_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    state = %{
      owner: owner,
      monitor: monitor,
      directory: directory,
      path: Path.join(directory, "model.maude")
    }

    if Process.alive?(owner), do: initialize(state, bytes), else: {:stop, :owner_lost}
  end

  defp initialize(state, bytes) do
    case File.mkdir(state.directory) do
      :ok -> write_snapshot(state, bytes)
      {:error, reason} -> snapshot_error(reason)
    end
  end

  defp write_snapshot(state, bytes) do
    with :ok <- File.chmod(state.directory, 0o700),
         :ok <- File.write(state.path, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(state.path, 0o400) do
      {:ok, state}
    else
      {:error, reason} ->
        remove(state.directory)
        snapshot_error(reason)
    end
  end

  defp snapshot_error(reason),
    do: {:stop, Error.new(:load_error, "cannot snapshot search model: #{inspect(reason)}")}

  @impl GenServer
  def handle_call(:path, {owner, _}, %{owner: owner} = state),
    do: {:reply, {:ok, state.path}, state}

  def handle_call(:close, {owner, _}, %{owner: owner} = state) do
    case remove(state.directory) do
      {:ok, _} ->
        {:stop, :normal, :ok, %{state | directory: nil}}

      {:error, reason, _} ->
        {:reply, {:error, Error.new(:load_error, "snapshot cleanup failed: #{inspect(reason)}")},
         state}
    end
  end

  def handle_call(_, _, state),
    do: {:reply, {:error, Error.new(:validation, "snapshot belongs to another caller")}, state}

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{monitor: monitor, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, %{directory: nil}), do: :ok
  def terminate(_, state), do: remove(state.directory)
  defp remove(directory), do: File.rm_rf(directory)
end
