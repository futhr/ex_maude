defmodule ExMaude.Result.Reduction do
  @moduledoc """
  Result of a Maude reduce operation.

  A reduction result contains the normalized term along with performance
  metrics like the number of rewrites applied and execution time.

  ## Structure

    * `:term` - The resulting `ExMaude.Term` after reduction
    * `:rewrites` - Number of rewrite steps applied
    * `:time_ms` - Time taken in milliseconds

  ## Maude Output Format

  The parser expects Maude's standard reduction output format:

      reduce in NAT : 1 + 2 + 3 .
      rewrites: 3 in 0ms cpu (0ms real) (~ rewrites/second)
      result Nat: 6

  Key patterns parsed:

  | Pattern | Description |
  |---------|-------------|
  | `rewrites: N` | Number of rewrite steps applied |
  | `in Nms` | Execution time in milliseconds |
  | `result Sort: Term` | The resulting term with its sort |

  ## Examples

      {:ok, result} = ExMaude.reduce_with_stats("NAT", "1 + 2 + 3")
      result.term.value   #=> "6"
      result.rewrites     #=> 3

      # Create manually
      term = ExMaude.Term.new("6", "Nat")
      result = ExMaude.Result.Reduction.new(term, rewrites: 3, time_ms: 1)

  ## See Also

    * `ExMaude.Result.Search` - For search operation results
    * `ExMaude.Term` - For term representation
    * `ExMaude.Maude.reduce/3` - To perform reductions
  """

  alias ExMaude.Term

  @enforce_keys [:term]
  defstruct [:term, :rewrites, :time_ms]

  @type t :: %__MODULE__{
          term: Term.t(),
          rewrites: non_neg_integer() | nil,
          time_ms: non_neg_integer() | nil
        }

  @doc """
  Creates a new Reduction result.

  ## Examples

      term = ExMaude.Term.new("6", "Nat")
      result = ExMaude.Result.Reduction.new(term, rewrites: 3, time_ms: 1)
  """
  @spec new(Term.t(), keyword()) :: t()
  def new(%Term{} = term, opts \\ []) do
    %__MODULE__{
      term: term,
      rewrites: Keyword.get(opts, :rewrites),
      time_ms: Keyword.get(opts, :time_ms)
    }
  end

  @doc """
  Parses Maude reduction output into a Reduction result.

  Extracts the term, rewrite count, and timing information from
  Maude's verbose output.
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(output, module \\ nil) do
    with {:ok, term} <- Term.parse(output, module) do
      {:ok,
       %__MODULE__{
         term: term,
         rewrites: parse_rewrites(output),
         time_ms: parse_time(output)
       }}
    end
  end

  defp parse_rewrites(output) do
    case Regex.run(~r/rewrites:\s*(\d+)/, output) do
      [_, count] -> String.to_integer(count)
      nil -> nil
    end
  end

  defp parse_time(output) do
    case Regex.run(~r/in\s*(\d+)ms/, output) do
      [_, ms] -> String.to_integer(ms)
      nil -> nil
    end
  end

  defimpl Inspect do
    @spec inspect(ExMaude.Result.Reduction.t(), Inspect.Opts.t()) :: String.t()
    def inspect(
          %ExMaude.Result.Reduction{term: term, rewrites: rewrites, time_ms: time_ms},
          _opts
        ) do
      parts = ["term: #{term.value} : #{term.sort}"]
      parts = if rewrites, do: parts ++ ["rewrites: #{rewrites}"], else: parts
      parts = if time_ms, do: parts ++ ["time: #{time_ms}ms"], else: parts

      "#ExMaude.Result.Reduction<#{Enum.join(parts, ", ")}>"
    end
  end
end
