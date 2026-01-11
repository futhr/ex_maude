defmodule ExMaude do
  @moduledoc """
  Elixir bindings for the Maude formal specification and verification system.

  ExMaude provides a high-level API for interacting with Maude, a formal
  specification language based on rewriting logic. It supports:

  - Term reduction and normalization
  - Module loading and management
  - Search operations for state space exploration
  - IoT rule conflict detection (via included Maude modules)
  - Pluggable backend architecture (Port, C-Node, NIF)

  ## Quick Start

      # Start the application (automatic with supervision tree)
      {:ok, _} = Application.ensure_all_started(:ex_maude)

      # Reduce a term
      {:ok, result} = ExMaude.reduce("NAT", "1 + 2 + 3")
      # => {:ok, "6"}

      # Load a custom module
      :ok = ExMaude.load_file("/path/to/my-module.maude")

      # Search for states
      {:ok, states} = ExMaude.search("MY-MOD", "initial", "final", max_depth: 10)

  ## Configuration

      config :ex_maude,
        backend: :port,                # :port | :cnode | :nif
        maude_path: nil,               # nil = auto-detect bundled binary
        pool_size: 4,                  # Worker processes
        pool_max_overflow: 2,          # Extra workers under load
        timeout: 5_000,                # Default command timeout
        start_pool: false,             # Auto-start on application boot
        use_pty: true                  # Use PTY wrapper (Port backend only)

  ## Architecture

  ExMaude uses a pluggable backend architecture with a Poolboy worker pool.
  Each worker maintains a persistent Maude session.

  ```
                        ExMaude (Public API)
                              │
                    ExMaude.Backend (Behaviour)
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
  Backend.Port         Backend.CNode         Backend.NIF
        │                     │                     │
        ▼                     ▼                     ▼
   PTY + Maude CLI    Erlang Distribution    Direct libmaude
  ```

  ## Backends

  | Backend | Isolation | Latency | Use Case |
  |---------|-----------|---------|----------|
  | `:port` | Full | Higher | Default, safe, works everywhere |
  | `:cnode` | Full | Medium | Production, structured data |
  | `:nif` | None | Lowest | Hot paths (Phase 3, not yet implemented) |

  """

  @doc """
  Reduces a term in the given module to its normal form.

  ## Examples

      ExMaude.reduce("NAT", "1 + 2")
      #=> {:ok, "3"}

      ExMaude.reduce("STRING", "\"hello\" + \" \" + \"world\"")
      #=> {:ok, "\"hello world\""}

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 5000)
  """
  @spec reduce(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate reduce(module, term, opts \\ []), to: ExMaude.Maude

  @doc """
  Rewrites a term using the rules in the given module.

  Unlike `reduce/3`, this applies rewrite rules (potentially non-deterministically)
  rather than just equations.

  ## Examples

      ExMaude.rewrite("MY-MOD", "initial-state", max_rewrites: 100)
      #=> {:ok, "final-state"}
  """
  @spec rewrite(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate rewrite(module, term, opts \\ []), to: ExMaude.Maude

  @doc """
  Searches for states reachable from an initial term.

  Uses Maude's `search` command to explore the state space defined by rewrite rules.

  ## Examples

      ExMaude.search("MY-MOD", "init", "target", max_depth: 10)
      #=> {:ok, [%{solution: 1, state_num: 5, substitution: %{"S" => "target"}}]}

  ## Options

    * `:max_depth` - Maximum search depth (default: 100)
    * `:max_solutions` - Maximum solutions to find (default: 1)
    * `:condition` - Additional search condition
    * `:timeout` - Maximum time in milliseconds (default: 30000)
  """
  @spec search(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  defdelegate search(module, initial, pattern, opts \\ []), to: ExMaude.Maude

  @doc """
  Loads a Maude file into all pool workers.

  ## Examples

      ExMaude.load_file("/path/to/my-module.maude")
      #=> :ok
  """
  @spec load_file(Path.t()) :: :ok | {:error, ExMaude.Error.t()}
  defdelegate load_file(path), to: ExMaude.Maude

  @doc """
  Loads a Maude module from a string.

  ## Examples

      ExMaude.load_module("fmod MY-MOD is sort Foo . endfm")
      #=> :ok
  """
  @spec load_module(String.t()) :: :ok | {:error, ExMaude.Error.t()}
  defdelegate load_module(source), to: ExMaude.Maude

  @doc """
  Executes a raw Maude command and returns the output.

  Use this for commands not covered by the high-level API.

  ## Examples

      ExMaude.execute("show module NAT .")
      #=> {:ok, "fmod NAT is ..."}
  """
  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate execute(command, opts \\ []), to: ExMaude.Maude

  @doc """
  Checks if Maude is available and returns version info.

  ## Examples

      ExMaude.version()
      #=> {:ok, "Maude 3.4"}
  """
  @spec version() :: {:ok, String.t()} | {:error, term()}
  defdelegate version(), to: ExMaude.Maude

  @doc """
  Returns the path to the bundled IoT rules Maude module.
  """
  @spec iot_rules_path() :: Path.t()
  def iot_rules_path do
    :ex_maude
    |> :code.priv_dir()
    |> Path.join("maude/iot-rules.maude")
  end
end
