defmodule ExMaude.Parser do
  @moduledoc """
  Parser for Maude command output.

  This module provides functions to parse various Maude command outputs
  into structured Elixir data. It handles the text-based responses from
  Maude and converts them into maps, lists, and tuples that are easier
  to work with in Elixir.

  ## Supported Output Formats

  The parser handles several types of Maude output:

    * **Reduction/Rewrite results** - `result Type: value` format
    * **Search solutions** - Multiple solutions with substitutions
    * **Error messages** - Warnings and errors from Maude
    * **Module listings** - Lists of loaded modules
    * **Term parsing** - Basic AST representation of Maude terms

  ## Usage

  This module is primarily used internally by `ExMaude.Maude` and `ExMaude.Server`,
  but can be used directly for custom output parsing:

      # Parse a reduce result
      {:ok, "42", "Nat"} = ExMaude.Parser.parse_result("result Nat: 42")

      # Parse search output
      solutions = ExMaude.Parser.parse_search_results(maude_output)

      # Check for errors in output
      :ok = ExMaude.Parser.parse_errors(clean_output)
      {:error, issues} = ExMaude.Parser.parse_errors("Error: bad input")

  ## Limitations

  The term parser (`parse_term/1`) provides basic parsing but does not handle
  all Maude syntax. Complex nested terms with parentheses in arguments may
  not parse correctly. For full parsing, consider using NimbleParsec-based
  parsers or Maude's own `parse` command.
  """

  @doc """
  Parses search command output into a list of solutions.

  ## Examples

      iex> output =
      ...>   "Solution 1 (state 5)\\nS:State --> active\\n\\nSolution 2 (state 8)\\nS:State --> inactive\\n"
      ...>
      ...> ExMaude.Parser.parse_search_results(output)
      [
        %{solution: 1, state_num: 5, substitution: %{"S:State" => "active"}},
        %{solution: 2, state_num: 8, substitution: %{"S:State" => "inactive"}}
      ]
  """
  @spec parse_search_results(String.t()) :: list(map())
  def parse_search_results(output) do
    output
    |> String.split(~r/Solution \d+/)
    # Drop empty first element
    |> Enum.drop(1)
    |> Enum.with_index(1)
    |> Enum.map(fn {solution_text, index} ->
      parse_solution(solution_text, index)
    end)
  end

  @doc """
  Parses a reduce/rewrite result to extract the value.

  ## Examples

      iex> ExMaude.Parser.parse_result("result Nat: 6")
      {:ok, "6", "Nat"}

      iex> ExMaude.Parser.parse_result("result Bool: true")
      {:ok, "true", "Bool"}
  """
  @spec parse_result(String.t()) :: {:ok, String.t(), String.t()} | {:error, :no_result}
  def parse_result(output) do
    # Match type names including parameterized types like List{Nat}
    case Regex.run(~r/result\s+([\w\{\},\s]+?):\s*(.+)/s, output) do
      [_, type, value] -> {:ok, String.trim(value), String.trim(type)}
      nil -> {:error, :no_result}
    end
  end

  @doc """
  Parses error messages from Maude output.

  ## Examples

      iex> ExMaude.Parser.parse_errors("Warning: blah\\nError: something bad")
      {:error, [warning: "blah", error: "something bad"]}
  """
  @spec parse_errors(String.t()) :: :ok | {:error, nonempty_list({:warning | :error, String.t()})}
  def parse_errors(output) do
    warnings =
      Regex.scan(~r/Warning:\s*(.+)/m, output)
      |> Enum.map(fn [_, msg] -> {:warning, String.trim(msg)} end)

    errors =
      Regex.scan(~r/Error:\s*(.+)/m, output)
      |> Enum.map(fn [_, msg] -> {:error, String.trim(msg)} end)

    case warnings ++ errors do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  @doc """
  Parses module list output.

  ## Examples

      iex> output = "fmod BOOL\\nfmod NAT\\nmod MY-MOD\\n"
      ...> ExMaude.Parser.parse_module_list(output)
      [
        %{type: :fmod, name: "BOOL"},
        %{type: :fmod, name: "NAT"},
        %{type: :mod, name: "MY-MOD"}
      ]
  """
  @spec parse_module_list(String.t()) :: list(map())
  def parse_module_list(output) do
    Regex.scan(~r/(fmod|mod|fth|th|view)\s+(\S+)/m, output)
    |> Enum.map(fn [_, type, name] ->
      %{type: parse_module_type(type), name: name}
    end)
  end

  # Convert module type string to atom using a whitelist approach
  # to avoid dynamic atom creation from untrusted input.
  # Note: The regex in parse_module_list/1 only matches these exact strings,
  # so the catch-all clause is defensive but unreachable in practice.
  defp parse_module_type("fmod"), do: :fmod
  defp parse_module_type("mod"), do: :mod
  defp parse_module_type("fth"), do: :fth
  defp parse_module_type("th"), do: :th
  defp parse_module_type("view"), do: :view
  # coveralls-ignore-start
  defp parse_module_type(_), do: :unknown
  # coveralls-ignore-stop

  @doc """
  Parses a Maude term into an Elixir term structure.

  This provides a basic AST representation of Maude terms.

  ## Examples

      iex> ExMaude.Parser.parse_term("s(s(0))")
      {:app, "s", [{:app, "s", [{:const, "0"}]}]}

      iex> ExMaude.Parser.parse_term("true and false")
      {:app, "and", [{:const, "true"}, {:const, "false"}]}
  """
  @spec parse_term(String.t()) :: {:const, String.t()} | {:app, String.t(), list()}
  def parse_term(input) do
    input
    |> String.trim()
    |> do_parse_term()
  end

  defp parse_solution(text, index) do
    # Extract state number if present
    state_num =
      case Regex.run(~r/\(state (\d+)\)/, text) do
        [_, num] -> String.to_integer(num)
        nil -> nil
      end

    # Parse substitutions (VAR:Sort --> value)
    substitution =
      Regex.scan(~r/(\S+)\s*-->\s*(.+)/m, text)
      |> Enum.map(fn [_, var, value] ->
        {String.trim(var), String.trim(value)}
      end)
      |> Map.new()

    %{
      solution: index,
      state_num: state_num,
      substitution: substitution
    }
  end

  defp do_parse_term(input) do
    cond do
      # Function application with no args: f()
      match = Regex.run(~r/^(\w+)\(\)$/, input) ->
        [_, func] = match
        {:app, func, []}

      # Function application: f(args)
      match = Regex.run(~r/^(\w+)\((.+)\)$/, input) ->
        [_, func, args_str] = match
        args = parse_args(args_str)
        {:app, func, args}

      # Infix operator: a op b
      match = Regex.run(~r/^(.+?)\s+(and|or|xor|\+|\*|-|\/|<|>|<=|>=|==|neq)\s+(.+)$/, input) ->
        [_, left, op, right] = match
        {:app, op, [do_parse_term(left), do_parse_term(right)]}

      # Constant
      true ->
        {:const, input}
    end
  end

  defp parse_args(args_str) do
    # Simple comma-separated arg parsing (doesn't handle nested parens well)
    args_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&do_parse_term/1)
  end
end
