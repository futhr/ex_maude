defmodule ExMaude.Application do
  @moduledoc """
  OTP Application callback module for ExMaude.

  This module implements the `Application` behaviour and is responsible for
  starting the ExMaude supervision tree when the application starts.

  ## Supervision Tree

  When the pool is enabled, the supervision tree looks like:

  ```
  ExMaude.Supervisor (one_for_one)
      │
      └── ExMaude.Pool (Poolboy)
              │
              ├── ExMaude.Server (worker 1)
              ├── ExMaude.Server (worker 2)
              └── ExMaude.Server (worker N)
  ```

  ## Configuration

  The pool is only started if explicitly enabled in configuration:

      config :ex_maude,
        start_pool: true,    # Enable the worker pool (default: false)
        pool_size: 4,        # Number of Maude worker processes
        pool_max_overflow: 2 # Extra workers allowed under load

  By default, `start_pool` is `false`, meaning no Maude processes are started
  automatically. This is useful for:

    * Testing without Maude installed
    * Applications that manage Maude processes manually
    * Build-time operations that don't need Maude

  ## Starting Manually

  If the pool is not started automatically, you can start it manually:

      # Add to your supervision tree
      children = [
        ExMaude.Pool.child_spec(pool_size: 4)
      ]

      # Or start directly
      {:ok, _} = Supervisor.start_child(ExMaude.Supervisor, ExMaude.Pool.child_spec())
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:ex_maude, :start_pool, false) do
        [ExMaude.Pool.child_spec()]
      else
        []
      end

    opts = [strategy: :one_for_one, name: ExMaude.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
