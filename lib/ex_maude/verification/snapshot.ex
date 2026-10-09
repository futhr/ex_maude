defmodule ExMaude.Verification.Snapshot do
  @moduledoc false
  use GenServer
  alias ExMaude.Error
  @maximum_bytes 16_777_216

  @doc false
  @spec start(binary()) :: {:ok, pid(), Path.t()} | {:error, Error.t()}
  def start(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@maximum_bytes do
    open({self(), bytes}, :path)
  end

  def start(_), do: {:error, Error.new(:validation, "snapshot requires bounded nonempty bytes")}

  @doc false
  @spec start_receipt(binary(), binary(), binary()) ::
          {:ok, pid(), %{model_path: Path.t(), checker_path: Path.t()}} | {:error, Error.t()}
  def start_receipt(model, checker, prelude)
      when is_binary(model) and is_binary(checker) and is_binary(prelude) do
    open({:receipt, self(), model, checker, prelude}, :receipt_paths)
  end

  def start_receipt(_, _, _),
    do:
      {:error, Error.new(:validation, "receipt snapshot requires binary model and checker bytes")}

  defp open(arguments, request) do
    case GenServer.start(__MODULE__, arguments) do
      {:ok, lease} ->
        {:ok, path} = GenServer.call(lease, request)
        {:ok, lease, path}

      {:error, %Error{}} = error ->
        error

      other ->
        {:error, Error.new(:load_error, "snapshot initialization failed: #{inspect(other)}")}
    end
  end

  @doc false
  @spec close(pid()) :: :ok | {:error, Error.t()}
  def close(lease) do
    GenServer.call(lease, :close)
  catch
    :exit, _ -> {:error, Error.new(:validation, "snapshot lease has ended")}
  end

  @impl GenServer
  def init({owner, bytes}) do
    initialize_owner(owner, "search", [{"model.maude", bytes, 0o400}])
  end

  def init({:receipt, owner, model, checker, prelude}) do
    initialize_owner(owner, "receipt", [
      {"iot-rules.maude", model, 0o400},
      {"maude", checker, 0o500},
      {"prelude.maude", prelude, 0o400}
    ])
  end

  defp initialize_owner(owner, kind, [{model_name, _, _} | _] = files) do
    monitor = Process.monitor(owner)

    directory =
      Path.join(
        System.tmp_dir!(),
        "ex_maude_#{kind}_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    state = %{
      owner: owner,
      monitor: monitor,
      directory: directory,
      path: Path.join(directory, model_name)
    }

    if Process.alive?(owner), do: initialize(state, files), else: {:stop, :owner_lost}
  end

  defp initialize(state, files) do
    case File.mkdir(state.directory) do
      :ok -> write_snapshot(state, files)
      {:error, reason} -> snapshot_error(reason)
    end
  end

  defp write_snapshot(state, files) do
    with :ok <- File.chmod(state.directory, 0o700),
         :ok <- write_files(state.directory, files) do
      {:ok, state}
    else
      {:error, reason} ->
        remove(state.directory)
        snapshot_error(reason)
    end
  end

  defp write_files(directory, files) do
    Enum.reduce_while(files, :ok, fn {name, bytes, mode}, :ok ->
      path = Path.join(directory, name)

      with :ok <- File.write(path, bytes, [:binary, :exclusive]),
           :ok <- File.chmod(path, mode) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp snapshot_error(reason),
    do: {:stop, Error.new(:load_error, "cannot snapshot search model: #{inspect(reason)}")}

  @impl GenServer
  def handle_call(:path, {owner, _}, %{owner: owner} = state),
    do: {:reply, {:ok, state.path}, state}

  def handle_call(:receipt_paths, {owner, _}, %{owner: owner} = state) do
    paths = %{
      model_path: Path.join(state.directory, "iot-rules.maude"),
      checker_path: Path.join(state.directory, "maude")
    }

    {:reply, {:ok, paths}, state}
  end

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
