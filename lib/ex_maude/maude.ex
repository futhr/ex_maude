defmodule ExMaude.Maude do
  @moduledoc """
  High-level API for interacting with Maude.

  This module provides convenient functions for common Maude operations,
  handling pool management, command formatting, and response parsing internally.

  ## Examples

      # Reduce a term to normal form
      {:ok, "6"} = ExMaude.Maude.reduce("NAT", "1 + 2 + 3")

      # Rewrite using rules
      {:ok, result} = ExMaude.Maude.rewrite("MY-MOD", "initial-state")

      # Search state space
      {:ok, solutions} = ExMaude.Maude.search("MY-MOD", "init", "goal")

      # Execute raw command
      {:ok, output} = ExMaude.Maude.execute("show module NAT .")

  ## Telemetry

  This module emits the following telemetry events:

  - `[:ex_maude, :command, :start]` - Emitted when a command starts
  - `[:ex_maude, :command, :stop]` - Emitted when a command completes
  - `[:ex_maude, :command, :exception]` - Emitted when a command raises

  Metadata includes `:operation` (`:reduce`, `:rewrite`, `:search`, `:execute`,
  `:parse`, `:load_file`, `:ensure_file_loaded`, `:load_module`) and `:module`
  (the Maude module name).

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  alias ExMaude.{Command, Config, Error, Parser, Pool, Preloads, Server, Telemetry}

  @default_timeout_ms 5_000
  @search_timeout_ms 30_000

  @doc """
  Reduces a term in the given module to its normal form.

  Uses Maude's `reduce` command which applies equations until a normal form
  is reached (equations are applied as simplification rules).

  ## Examples

      ExMaude.Maude.reduce("NAT", "1 + 2 + 3")
      #=> {:ok, "6"}

      ExMaude.Maude.reduce("BOOL", "true and false")
      #=> {:ok, "false"}

  ## Options

    * `:timeout` - Maximum time in ms (default: 5000)
  """
  @spec reduce(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def reduce(module, term, opts \\ []) do
    Telemetry.span([:ex_maude, :command], %{operation: :reduce, module: module}, fn ->
      do_execute(Command.reduce(module, term), opts)
    end)
  end

  @doc """
  Rewrites a term using the rules in the given module.

  Uses Maude's `rewrite` command which applies both equations and rules.
  Rules can be non-deterministic and may not terminate.

  ## Examples

      ExMaude.Maude.rewrite("MY-MOD", "initial-state", max_rewrites: 100)
      #=> {:ok, "final-state"}

  ## Options

    * `:max_rewrites` - Maximum number of rule applications (default: unlimited)
    * `:timeout` - Maximum time in ms (default: 5000)
  """
  @spec rewrite(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def rewrite(module, term, opts \\ []) do
    Telemetry.span([:ex_maude, :command], %{operation: :rewrite, module: module}, fn ->
      do_execute(Command.rewrite(module, term, opts), opts)
    end)
  end

  @doc """
  Searches for states reachable from an initial term.

  Uses Maude's `search` command to explore the state space defined by rewrite rules.
  Returns solutions matching the target pattern.

  ## Examples

      ExMaude.Maude.search("MY-MOD", "init", "goal")
      #=> {:ok, [%{solution: 1, state_num: 5, substitution: %{}}]}

      ExMaude.Maude.search("MY-MOD", "init", "S:State", condition: "property(S)")
      #=> {:ok, [%{solution: 1, state_num: 3, substitution: %{"S:State" => "s1"}}]}

  ## Options

    * `:max_depth` - Maximum search depth (default: 100)
    * `:max_solutions` - Maximum solutions to find (default: 1)
    * `:arrow` - Search arrow: `=>1`, `=>+`, `=>*`, `=>!` (default: `=>*`)
    * `:condition` - Additional search condition
    * `:timeout` - Maximum time in ms (default: 30000)
  """
  @spec search(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def search(module, initial, pattern, opts \\ []) do
    Telemetry.span([:ex_maude, :command], %{operation: :search, module: module}, fn ->
      timeout = Keyword.get(opts, :timeout, Config.timeout(@search_timeout_ms))
      command = Command.search(module, initial, pattern, opts)

      case do_execute(command, Keyword.put(opts, :timeout, timeout)) do
        {:ok, output} -> {:ok, Parser.parse_search_results(output)}
        error -> error
      end
    end)
  end

  @doc """
  Loads a Maude file into all pool workers.

  The file is loaded into every worker in the pool to ensure consistent
  module availability across all operations.

  ## Examples

      ExMaude.Maude.load_file("/path/to/my-module.maude")
      #=> :ok

  ## Options

    * `:pool` - Registered pool name (default: `:ex_maude_pool`)
  """
  @spec load_file(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def load_file(path, opts \\ []) do
    Telemetry.span(
      [:ex_maude, :command],
      %{operation: :load_file, module: "file"},
      fn -> do_load_file(path, opts) end
    )
  end

  @doc """
  Loads a Maude file into a pool at most once, safely under concurrency.

  `load_file/2` broadcasts to every worker on every call, including workers
  currently checked out serving other reductions — those loads fail, so N
  concurrent callers mostly see `:load_error` even though the file is fine.

  This returns `:ok` if the source path was successfully preloaded or the
  file's content digest is already recorded for the pool. Otherwise it loads
  inside a per-node lock, re-checking after acquiring it. Prefer it on any path
  that can run concurrently.

  A residual race remains if a *new* module is loaded while a long-running
  command holds a worker; `:preload_modules` avoids it for known modules.

  ## Options

    * `:pool` — Registered pool name (default: `:ex_maude_pool`)
  """
  @spec ensure_file_loaded(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def ensure_file_loaded(path, opts \\ []) do
    Telemetry.span(
      [:ex_maude, :command],
      %{operation: :ensure_file_loaded, module: "file"},
      fn -> do_ensure_file_loaded(path, opts) end
    )
  end

  defp do_ensure_file_loaded(path, opts) do
    pool = Keyword.get(opts, :pool, :ex_maude_pool)

    cond do
      not File.exists?(path) -> {:error, Error.file_not_found(path)}
      already_loaded?(path, pool) -> :ok
      true -> load_once(path, pool, opts)
    end
  end

  defp load_once(path, pool, opts) do
    # :global lock IDs are {resource, requester}. The resource must be shared
    # by competing callers while the requester must identify this process;
    # using a constant requester would make the lock re-entrant across callers.
    resource = {__MODULE__, :ensure_file_loaded, node(), pool, Path.expand(path)}
    lock = {resource, self()}

    case :global.trans(lock, fn -> load_unless_loaded(path, pool, opts) end) do
      :aborted ->
        {:error, Error.new(:load_error, "Could not acquire load lock for #{path}")}

      result ->
        result
    end
  end

  # Re-check inside the lock: while we waited, the caller that held it may
  # have completed the load we were about to duplicate.
  defp load_unless_loaded(path, pool, opts) do
    if already_loaded?(path, pool), do: :ok, else: do_load_file(path, opts)
  end

  # Both successful startup preloads and runtime loads record the same
  # content-derived identity without requiring a pool call here.
  defp already_loaded?(path, pool) do
    case Preloads.identity(path) do
      {:ok, identity} -> Enum.any?(Preloads.loaded_for_pool(pool), &same_path?(&1, identity))
      :error -> false
    end
  end

  defp same_path?(left, right), do: Path.expand(left) == Path.expand(right)

  @doc """
  Loads a Maude module from a string.

  The module definition is loaded into all pool workers.

  ## Examples

      source = "fmod MY-MOD is sort Foo . endfm"
      ExMaude.Maude.load_module(source)
      #=> :ok

  ## Options

    * `:pool` - Registered pool name (default: `:ex_maude_pool`)
  """
  @spec load_module(String.t(), keyword()) :: :ok | {:error, term()}
  def load_module(source, opts \\ []) do
    Telemetry.span(
      [:ex_maude, :command],
      %{operation: :load_module, module: "source"},
      fn -> do_load_module(source, opts) end
    )
  end

  defp do_load_file(path, opts) do
    if File.exists?(path) do
      pool = Keyword.get(opts, :pool, :ex_maude_pool)

      with {:ok, cached_path} <- cache_module(path),
           :ok <- load_cached_file(cached_path, pool) do
        Preloads.remember(pool, cached_path)
      end
    else
      {:error, Error.file_not_found(path)}
    end
  end

  # The path is generated entirely from the runtime temp directory and a
  # unique integer, then checked again before either filesystem operation.
  # sobelow_skip ["Traversal.FileModule"]
  defp do_load_module(source, opts) do
    # The path is built from System.tmp_dir! and a unique integer (no user
    # input), then expanded and bounds-checked as defense in depth before
    # File.write!.
    tmp_dir = System.tmp_dir!()
    filename = "ex_maude_#{:erlang.unique_integer([:positive])}.maude"
    tmp_path = Path.join(tmp_dir, filename)

    expanded_path = Path.expand(tmp_path)
    expanded_tmp = Path.expand(tmp_dir)

    if String.starts_with?(expanded_path, expanded_tmp) do
      try do
        File.write!(expanded_path, source)
        do_load_file(expanded_path, opts)
      after
        File.rm(expanded_path)
      end
    else
      # Unreachable under normal Path.expand behavior.
      {:error, Error.invalid_path("Generated path escapes temp directory")}
    end
  end

  defp load_cached_file(path, pool) do
    case Pool.broadcast(
           fn worker ->
             case Server.load_file(worker, path) do
               :ok -> Preloads.mark_loaded(pool, [path], worker)
               error -> error
             end
           end,
           pool: pool
         ) do
      {:ok, results} ->
        if Enum.all?(results, &(&1 == :ok)) do
          :ok
        else
          failures = Enum.reject(results, &(&1 == :ok))
          {:error, Error.partial_load(failures)}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # `path` was validated by load_file/2. The cache directory comes from the
  # runtime and the filename is a SHA-256 digest, so neither destination
  # component contains caller-controlled path segments.
  # sobelow_skip ["Traversal.FileModule"]
  defp cache_module(path) do
    with {:ok, source} <- File.read(path),
         digest <- Base.encode16(:crypto.hash(:sha256, source), case: :lower),
         cache_dir <- Path.join([System.tmp_dir!(), "ex_maude", "preloads"]),
         :ok <- File.mkdir_p(cache_dir),
         cached_path <- Path.join(cache_dir, digest <> ".maude"),
         :ok <- File.write(cached_path, source, [:binary]) do
      {:ok, cached_path}
    else
      {:error, reason} ->
        {:error, Error.new(:load_error, "Could not cache Maude module: #{inspect(reason)}")}
    end
  end

  @doc """
  Executes a raw Maude command.

  Use this for commands not covered by the high-level API.

  ## Examples

      ExMaude.Maude.execute("show module NAT .")
      #=> {:ok, "fmod NAT is ..."}

      ExMaude.Maude.execute("parse in NAT : 1 + 2 .")
      #=> {:ok, "1 + 2"}
  """
  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute(command, opts \\ []) do
    Telemetry.span([:ex_maude, :command], %{operation: :execute, module: "raw"}, fn ->
      do_execute(command, opts)
    end)
  end

  # Bypass the telemetry span so the calling function can wrap it instead.
  defp do_execute(command, opts) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(@default_timeout_ms))

    # The +1s keeps the checkout wait from expiring before a worker whose
    # in-flight command is about to hit its own deadline frees up.
    Pool.transaction(
      fn worker ->
        Server.execute(worker, command, timeout: timeout)
      end,
      checkout_timeout: timeout + 1_000,
      pool: Keyword.get(opts, :pool, :ex_maude_pool)
    )
  end

  @doc """
  Returns the Maude interpreter version, e.g. `{:ok, "3.5.1"}`.

  Runs `maude --version` on the binary resolved by `ExMaude.Binary.find/0`
  (configured path, `MAUDE_PATH`, local install, then system PATH). No pool or
  worker is involved, so this works without starting a pool.

  ## Examples

      ExMaude.Maude.version()
      #=> {:ok, "3.5.1"}
  """
  @spec version() :: {:ok, String.t()} | {:error, Error.t()}
  def version do
    case ExMaude.Binary.find() do
      nil ->
        {:error, Error.file_not_found("maude (configure :maude_path or run `mix maude.install`)")}

      path ->
        version(path)
    end
  end

  @doc false
  # sobelow_skip ["CI.System"]
  # The path comes from ExMaude.Binary.find/0 (explicit config, the local
  # priv binary, or System.find_executable) — the same trust chain every
  # backend already executes as a worker; --version adds no new exposure.
  @spec version(Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def version(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error,
         Error.exception(:maude_crash, "maude --version exited #{status}: #{String.trim(output)}")}
    end
  rescue
    e in ErlangError ->
      {:error, Error.exception(:file_not_found, "cannot run #{path}: #{inspect(e.original)}")}
  end

  @doc """
  Parses a term in the given module without reducing.

  ## Examples

      ExMaude.Maude.parse("NAT", "1 + 2 + 3")
      #=> {:ok, "1 + (2 + 3)"}
  """
  @spec parse(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def parse(module, term, opts \\ []) do
    Telemetry.span([:ex_maude, :command], %{operation: :parse, module: module}, fn ->
      do_execute(Command.parse(module, term), opts)
    end)
  end

  @doc """
  Shows information about a module.

  ## Examples

      ExMaude.Maude.show_module("NAT")
      #=> {:ok, "fmod NAT is ..."}
  """
  @spec show_module(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def show_module(module, opts \\ []) do
    execute("show module #{module} .", opts)
  end

  @doc """
  Lists all loaded modules.
  """
  @spec list_modules(keyword()) :: {:ok, String.t()} | {:error, term()}
  def list_modules(opts \\ []) do
    execute("show modules .", opts)
  end
end
