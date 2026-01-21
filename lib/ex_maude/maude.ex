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
  `:parse`, `:load_file`, `:load_module`) and `:module` (the Maude module name).

  See `ExMaude.Telemetry` for full event documentation and integration examples.
  """

  alias ExMaude.{Error, Pool, Server, Parser, Telemetry}

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
      command = "reduce in #{module} : #{term}"
      do_execute(command, opts)
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
      max_rewrites = Keyword.get(opts, :max_rewrites)

      command =
        if max_rewrites do
          "rewrite [#{max_rewrites}] in #{module} : #{term}"
        else
          "rewrite in #{module} : #{term}"
        end

      do_execute(command, opts)
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
      timeout = Keyword.get(opts, :timeout, @search_timeout_ms)
      command = build_search_command(module, initial, pattern, opts)

      case do_execute(command, timeout: timeout) do
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
  """
  @spec load_file(Path.t()) :: :ok | {:error, Error.t()}
  def load_file(path) do
    unless File.exists?(path) do
      {:error, Error.file_not_found(path)}
    else
      results =
        Pool.broadcast(fn worker ->
          Server.load_file(worker, path)
        end)

      if Enum.all?(results, &(&1 == :ok)) do
        :ok
      else
        # coveralls-ignore-start
        # This branch requires a partial failure across pool workers
        failures = Enum.reject(results, &(&1 == :ok))
        {:error, Error.partial_load(failures)}
        # coveralls-ignore-stop
      end
    end
  end

  @doc """
  Loads a Maude module from a string.

  The module definition is loaded into all pool workers.

  ## Examples

      source = "fmod MY-MOD is sort Foo . endfm"
      ExMaude.Maude.load_module(source)
      #=> :ok
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_module(String.t()) :: :ok | {:error, term()}
  def load_module(source) do
    # Create a temporary file for the module in a controlled location.
    # The path is constructed from System.tmp_dir! and a unique integer,
    # with no user input in the path - safe from directory traversal.
    tmp_dir = System.tmp_dir!()
    filename = "ex_maude_#{:erlang.unique_integer([:positive])}.maude"
    tmp_path = Path.join(tmp_dir, filename)

    # Verify path stays within tmp_dir (defense in depth)
    expanded_path = Path.expand(tmp_path)
    expanded_tmp = Path.expand(tmp_dir)

    if String.starts_with?(expanded_path, expanded_tmp) do
      try do
        File.write!(expanded_path, source)
        load_file(expanded_path)
      after
        File.rm(expanded_path)
      end
    else
      # coveralls-ignore-start
      # This branch can only be reached if Path.expand behaves unexpectedly
      {:error, Error.invalid_path("Generated path escapes temp directory")}
      # coveralls-ignore-stop
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

  # Internal execute without telemetry (used by instrumented functions)
  defp do_execute(command, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    Pool.transaction(
      fn worker ->
        Server.execute(worker, command, timeout: timeout)
      end,
      timeout: timeout + 1_000
    )
  end

  @doc """
  Returns Maude version information.

  ## Examples

      ExMaude.Maude.version()
      #=> {:ok, "Maude (version available at runtime)"}
  """
  @spec version() :: {:ok, String.t()} | {:error, term()}
  def version do
    # The version is shown in the banner, but we suppress it
    # So we need to get it another way
    case execute("show modules .") do
      {:ok, _} ->
        # If we can execute a command, Maude is working
        # Get version from environment or default
        {:ok, "Maude (version available at runtime)"}

      error ->
        error
    end
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
      command = "parse in #{module} : #{term}"
      do_execute(command, opts)
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

  defp build_search_command(module, initial, pattern, opts) do
    max_depth = Keyword.get(opts, :max_depth, 100)
    max_solutions = Keyword.get(opts, :max_solutions, 1)
    arrow = Keyword.get(opts, :arrow, "=>*")
    condition = Keyword.get(opts, :condition)

    base = "search [#{max_solutions}, #{max_depth}] in #{module} : #{initial} #{arrow} #{pattern}"

    if condition do
      "#{base} such that #{condition}"
    else
      base
    end
  end
end
