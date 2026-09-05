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
  def runtime_for_pool(pool \\ @default_pool), do: Enum.reverse(current(pool).paths)

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
    update(pool, fn state ->
      if path in state.paths, do: state, else: %{state | paths: [path | state.paths]}
    end)
  end

  @doc false
  @spec mark_loaded(atom(), [Path.t()], pid()) :: :ok
  def mark_loaded(pool, paths, worker \\ self()) do
    identities = MapSet.new(Enum.flat_map(paths, &identity_list/1))

    update(pool, fn state ->
      loaded =
        state.loaded
        |> Map.filter(fn {pid, _} -> Process.alive?(pid) end)
        |> Map.update(worker, identities, &MapSet.union(&1, identities))

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
        {:ok, Path.expand(path) <> ":" <> digest}

      {:error, _} ->
        :error
    end
  end

  @doc false
  @spec cache_source(atom(), String.t()) :: {:ok, Path.t()} | {:error, ExMaude.Error.t()}
  # Files live in a private random directory and are created exclusively.
  # sobelow_skip ["Traversal.FileModule"]
  def cache_source(pool, source) when is_binary(source) do
    locked(fn -> cache_for_live_pool(Process.whereis(pool), pool, source) end)
  end

  defp cache_for_live_pool(nil, _, _), do: {:error, ExMaude.Error.pool_error(:not_started)}

  defp cache_for_live_pool(_, pool, source) do
    with :ok <- ensure_cache_dir(pool),
         path =
           Path.join(
             current(pool).cache_dir,
             Base.encode16(:crypto.hash(:sha256, source)) <> ".maude"
           ),
         :ok <- write_source(path, source) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error, ExMaude.Error.new(:load_error, "Could not cache module: #{inspect(reason)}")}
    end
  end

  defp ensure_cache_dir(pool) do
    if current(pool).cache_dir do
      :ok
    else
      suffix = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      dir = Path.join(System.tmp_dir!(), "ex_maude-" <> suffix)

      with :ok <- File.mkdir(dir), :ok <- File.chmod(dir, 0o700) do
        update(pool, &%{&1 | cache_dir: dir})
      end
    end
  end

  defp write_source(path, source) do
    case File.write(path, source, [:binary, :exclusive]) do
      {:error, :eexist} -> :ok
      result -> result
    end
  end

  defp current(pool) do
    owner = Process.whereis(pool)

    case Map.get(Application.get_env(:ex_maude, @state_key, %{}), pool) do
      %{owner: ^owner} = state when is_pid(owner) -> state
      _ -> %{owner: owner, paths: [], loaded: %{}, cache_dir: nil}
    end
  end

  defp update(pool, fun) do
    locked(fn -> update_live_pool(Process.whereis(pool), pool, fun) end)
    :ok
  end

  defp update_live_pool(nil, _, _), do: :ok

  defp update_live_pool(owner, pool, fun) do
    all = Application.get_env(:ex_maude, @state_key, %{})

    unless match?(%{owner: ^owner}, Map.get(all, pool)) do
      spawn(fn -> cleanup_on_exit(pool, owner) end)
    end

    Application.put_env(:ex_maude, @state_key, Map.put(all, pool, fun.(current(pool))))
  end

  defp cleanup_on_exit(pool, owner) do
    ref = Process.monitor(owner)

    receive do
      {:DOWN, ^ref, :process, ^owner, _} ->
        locked(fn ->
          all = Application.get_env(:ex_maude, @state_key, %{})

          if match?(%{owner: ^owner}, Map.get(all, pool)) do
            state = Map.fetch!(all, pool)
            if state.cache_dir, do: File.rm_rf(state.cache_dir)
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
