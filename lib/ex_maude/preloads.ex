defmodule ExMaude.Preloads do
  @moduledoc false

  @runtime_key :runtime_preload_modules_by_pool
  @loaded_key :loaded_module_identities_by_pool
  @default_pool :ex_maude_pool

  @doc false
  @spec for_pool(atom(), [Path.t()] | nil) :: [Path.t()]
  def for_pool(pool \\ @default_pool, configured \\ nil) when is_atom(pool) do
    baseline = configured || Application.get_env(:ex_maude, :preload_modules, [])
    Enum.uniq(baseline ++ runtime_for_pool(pool))
  end

  @doc false
  @spec runtime_for_pool(atom()) :: [Path.t()]
  def runtime_for_pool(pool \\ @default_pool) when is_atom(pool) do
    :ex_maude
    |> Application.get_env(@runtime_key, %{})
    |> Map.get(pool, [])
  end

  @doc false
  @spec loaded_for_pool(atom()) :: [Path.t()]
  def loaded_for_pool(pool \\ @default_pool) when is_atom(pool) do
    identities =
      :ex_maude
      |> Application.get_env(@loaded_key, %{})
      |> Map.get(pool, [])

    Enum.uniq(runtime_for_pool(pool) ++ identities)
  end

  @doc false
  @spec remember(atom(), Path.t()) :: :ok
  def remember(pool, path) when is_atom(pool) and is_binary(path) do
    resource = {__MODULE__, @runtime_key, node()}

    :global.trans({resource, self()}, fn ->
      runtime = Application.get_env(:ex_maude, @runtime_key, %{})

      modules =
        runtime
        |> Map.get(pool, [])
        |> Kernel.++([path])
        |> Enum.uniq()

      Application.put_env(:ex_maude, @runtime_key, Map.put(runtime, pool, modules))
    end)

    :ok
  end

  @doc false
  @spec mark_loaded(atom(), [Path.t()]) :: :ok
  def mark_loaded(pool, paths) when is_atom(pool) and is_list(paths) do
    identities = Enum.flat_map(paths, &identity_list/1)
    resource = {__MODULE__, @loaded_key, node()}

    :global.trans({resource, self()}, fn ->
      loaded = Application.get_env(:ex_maude, @loaded_key, %{})
      pool_identities = Enum.uniq(Map.get(loaded, pool, []) ++ identities)
      Application.put_env(:ex_maude, @loaded_key, Map.put(loaded, pool, pool_identities))
    end)

    :ok
  end

  @doc false
  @spec identity(Path.t()) :: {:ok, Path.t()} | :error
  # Reading the path is required to derive the identity of a module that a
  # backend has just loaded. This performs no authorization or source write.
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

  defp identity_list(path) do
    case identity(path) do
      {:ok, identity} -> [identity]
      :error -> []
    end
  end
end
