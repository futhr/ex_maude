defmodule ExMaude.Pool do
  alias ExMaude.{Backend, Error}

  @moduledoc """
  Poolboy-based pool of Maude server processes.

  This module manages a pool of backend workers (Port, C-Node, or NIF), providing:
  - Automatic worker checkout/checkin
  - Connection pooling for concurrent operations
  - Worker supervision and restart

  ## Configuration

      config :ex_maude,
        backend: :port,         # :port | :cnode | :nif
        pool_size: 4,           # Number of Maude processes
        pool_max_overflow: 2    # Extra workers under load

  ## Usage

  The pool is typically accessed via `ExMaude.Maude` rather than directly:

      # Checkout, execute, and checkin automatically
      ExMaude.Pool.transaction(fn worker ->
        ExMaude.Server.execute(worker, "reduce in NAT : 1 + 2 .")
      end)

  ## Architecture

  ```
  ExMaude.Pool (Poolboy)
      │
      ├── Worker 1 (Backend.impl()) ─── Maude Process 1
      ├── Worker 2 (Backend.impl()) ─── Maude Process 2
      ├── Worker 3 (Backend.impl()) ─── Maude Process 3
      └── Worker 4 (Backend.impl()) ─── Maude Process 4
  ```

  ## Telemetry

  This module emits the following telemetry events:

  - `[:ex_maude, :pool, :checkout, :start]` - Emitted when checkout begins
  - `[:ex_maude, :pool, :checkout, :stop]` - Emitted when checkout completes

  Measurements include `:duration` in native time units.
  Metadata includes `:result` (`:ok` or `:error`) and `:backend`.

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  @pool_name :ex_maude_pool
  @default_pool_size 4
  @default_max_overflow 2
  @checkout_timeout 5_000

  @doc """
  Returns the child spec for the pool supervisor.

  ## Options

    * `:worker_module` - Override the backend module (default: `Backend.impl()`)
    * `:pool_size` - Number of workers (default: from config)
    * `:pool_max_overflow` - Extra workers under load (default: from config)

  """
  @spec child_spec(keyword()) ::
          {atom(), {:poolboy, :start_link, [any()]}, :permanent, 5000, :worker, [:poolboy]}
  def child_spec(opts \\ []) do
    worker_module = opts[:worker_module] || Backend.impl()

    pool_config = [
      name: {:local, @pool_name},
      worker_module: worker_module,
      size: opts[:pool_size] || config_pool_size(),
      max_overflow: opts[:pool_max_overflow] || config_max_overflow()
    ]

    worker_opts = Keyword.drop(opts, [:pool_size, :pool_max_overflow, :worker_module])

    :poolboy.child_spec(@pool_name, pool_config, worker_opts)
  end

  @doc """
  Executes a function with a checked-out worker.

  The worker is automatically returned to the pool after the function completes.

  ## Examples

      ExMaude.Pool.transaction(fn worker ->
        ExMaude.Server.execute(worker, "reduce in NAT : 1 + 2 .")
      end)

  ## Options

    * `:timeout` - Checkout timeout in ms (default: 5000)
  """
  @spec transaction((pid() -> result), keyword()) :: result | {:error, Error.t()}
        when result: any()
  def transaction(fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, @checkout_timeout)
    start_time = System.monotonic_time()

    backend = config_backend()

    :telemetry.execute(
      [:ex_maude, :pool, :checkout, :start],
      %{system_time: System.system_time()},
      %{backend: backend}
    )

    try do
      result =
        :poolboy.transaction(
          @pool_name,
          fn worker -> fun.(worker) end,
          timeout
        )

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ex_maude, :pool, :checkout, :stop],
        %{duration: duration},
        %{result: :ok, backend: backend}
      )

      result
    catch
      :exit, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ex_maude, :pool, :checkout, :stop],
          %{duration: duration},
          %{result: :error, backend: backend}
        )

        {:error, Error.pool_error(reason)}
    end
  end

  @doc """
  Broadcasts a function to all workers in the pool.

  Useful for operations that need to affect all Maude sessions,
  such as loading a module.

  ## Examples

      ExMaude.Pool.broadcast(fn worker ->
        ExMaude.Server.load_file(worker, "/path/to/module.maude")
      end)
  """
  @spec broadcast(fun()) :: [:ok | {:error, Error.t() | term()}]
  def broadcast(fun) when is_function(fun, 1) do
    pool_size = config_pool_size() + config_max_overflow()

    # Checkout all workers (up to pool size + overflow)
    workers =
      for _ <- 1..pool_size do
        try do
          :poolboy.checkout(@pool_name, false)
        catch
          :exit, _ -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # Execute function on each worker
    results =
      workers
      |> Task.async_stream(
        fn worker ->
          try do
            fun.(worker)
          after
            :poolboy.checkin(@pool_name, worker)
          end
        end,
        timeout: 30_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, Error.pool_error({:exit, reason})}
      end)

    results
  end

  @doc """
  Returns the current pool status.

  ## Examples

      ExMaude.Pool.status()
      #=> %{size: 4, overflow: 0, available: 3, in_use: 1}
  """
  @spec status() :: %{
          size: non_neg_integer(),
          overflow: non_neg_integer(),
          available: non_neg_integer(),
          in_use: integer(),
          state: atom()
        }
  def status do
    try do
      {state_name, workers, overflow, monitors} = :poolboy.status(@pool_name)

      # workers is the count of available workers in the pool
      # monitors is the count of checked-out workers being monitored
      # Size is the configured pool size
      pool_size = config_pool_size()

      %{
        size: pool_size,
        overflow: overflow,
        available: workers,
        in_use: monitors,
        state: state_name
      }
    catch
      :exit, _ ->
        %{size: 0, overflow: 0, available: 0, in_use: 0, state: :not_started}
    end
  end

  @doc """
  Checks out a worker from the pool.

  Remember to check the worker back in with `checkin/1`.
  Prefer `transaction/2` for automatic resource management.
  """
  @spec checkout(keyword()) :: pid() | :full | {:error, Error.t()}
  def checkout(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @checkout_timeout)
    block = Keyword.get(opts, :block, true)

    try do
      :poolboy.checkout(@pool_name, block, timeout)
    catch
      :exit, {:timeout, _} -> {:error, Error.pool_error(:timeout)}
      :exit, {:full, _} -> {:error, Error.pool_error(:full)}
    end
  end

  @doc """
  Returns a worker to the pool.
  """
  @spec checkin(pid()) :: :ok
  def checkin(worker) do
    :poolboy.checkin(@pool_name, worker)
  end

  defp config_pool_size do
    Application.get_env(:ex_maude, :pool_size, @default_pool_size)
  end

  defp config_max_overflow do
    Application.get_env(:ex_maude, :pool_max_overflow, @default_max_overflow)
  end

  defp config_backend do
    Application.get_env(:ex_maude, :backend, :port)
  end
end
