defmodule ExMaude.Preloads do
  @moduledoc false

  @state_key :preload_state_by_pool
  @default_pool :ex_maude_pool

  @doc false
  @spec for_pool(atom(), [Path.t()] | nil) :: [Path.t()]
  def for_pool(pool \\ @default_pool, configured \\ nil) do
    Enum.uniq(
      (configured || Application.get_env(:ex_maude, :preload_modules, [])) ++
        runtime_for_pool(pool)
    )
  end

  @doc false
  @spec runtime_for_pool(atom()) :: [Path.t()]
  def runtime_for_pool(pool \\ @default_pool), do: current(pool).paths

  @doc false
  @spec loaded_for_pool(atom()) :: [Path.t()]
  def loaded_for_pool(pool \\ @default_pool) do
    state = current(pool)

    case workers(pool) do
      [] ->
        []

      workers ->
        workers
        |> Enum.map(&Map.get(state.loaded, &1, MapSet.new()))
        |> Enum.reduce(&MapSet.intersection/2)
        |> MapSet.to_list()
    end
  end

  @doc false
  @spec remember(atom(), Path.t()) :: :ok
  def remember(pool, path) do
    update(pool, fn state -> %{state | paths: Enum.uniq(state.paths ++ [path])} end)
  end

  @doc false
  @spec mark_loaded(atom(), [Path.t()], pid()) :: :ok
  def mark_loaded(pool, paths, worker \\ self()) do
    identities = MapSet.new(Enum.flat_map(paths, &identity_list/1))

    update(pool, fn state ->
      loaded = Map.update(state.loaded, worker, identities, &MapSet.union(&1, identities))
      %{state | loaded: loaded}
    end)
  end

  @doc false
  @spec identity(Path.t()) :: {:ok, Path.t()} | :error
  # sobelow_skip ["Traversal.FileModule"]
  def identity(path) do
    case File.read(path) do
      {:ok, source} ->
        digest = Base.encode16(:crypto.hash(:sha256, source), case: :lower)
        {:ok, Path.join([System.tmp_dir!(), "ex_maude", "preloads", digest <> ".maude"])}

      {:error, _} ->
        :error
    end
  end

  defp current(pool) do
    owner = Process.whereis(pool)

    case Map.get(Application.get_env(:ex_maude, @state_key, %{}), pool) do
      %{owner: ^owner} = state when is_pid(owner) -> state
      _ -> %{owner: owner, paths: [], loaded: %{}}
    end
  end

  defp update(pool, fun) do
    locked(fn ->
      case Process.whereis(pool) do
        nil ->
          :ok

        owner ->
          all = Application.get_env(:ex_maude, @state_key, %{})

          unless match?(%{owner: ^owner}, Map.get(all, pool)) do
            spawn(fn -> cleanup_on_exit(pool, owner) end)
          end

          Application.put_env(:ex_maude, @state_key, Map.put(all, pool, fun.(current(pool))))
      end
    end)

    :ok
  end

  defp cleanup_on_exit(pool, owner) do
    ref = Process.monitor(owner)

    receive do
      {:DOWN, ^ref, :process, ^owner, _} ->
        locked(fn ->
          all = Application.get_env(:ex_maude, @state_key, %{})

          if match?(%{owner: ^owner}, Map.get(all, pool)) do
            Application.put_env(:ex_maude, @state_key, Map.delete(all, pool))
          end
        end)
    end
  end

  defp locked(fun), do: :global.trans({{__MODULE__, node()}, self()}, fun, [node()])

  defp workers(pool) do
    pool
    |> GenServer.call(:get_all_workers)
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  catch
    :exit, _ -> []
  end

  defp identity_list(path) do
    case identity(path) do
      {:ok, identity} -> [identity]
      :error -> []
    end
  end
end
