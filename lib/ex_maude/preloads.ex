defmodule ExMaude.Preloads do
  @moduledoc false

  @runtime_key :runtime_preload_modules_by_pool
  @default_pool :ex_maude_pool

  @doc false
  @spec for_pool(atom(), [Path.t()] | nil) :: [Path.t()]
  def for_pool(pool \\ @default_pool, configured \\ nil) when is_atom(pool) do
    baseline = configured || Application.get_env(:ex_maude, :preload_modules, [])
    runtime = Application.get_env(:ex_maude, @runtime_key, %{})
    Enum.uniq(baseline ++ Map.get(runtime, pool, []))
  end

  @doc false
  @spec remember(atom(), Path.t()) :: :ok
  def remember(pool, path) when is_atom(pool) and is_binary(path) do
    :global.trans({__MODULE__, @runtime_key}, fn ->
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
end
