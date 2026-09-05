defmodule ExMaude.ConflictOutput do
  @moduledoc false

  alias ExMaude.{Balanced, Error, Parser, Syntax}

  @doc false
  @spec parse(String.t(), String.t(), String.t(), (String.t() -> map() | nil)) ::
          {:ok, [map()]} | {:error, Error.t()}
  def parse(output, empty, separator, parser) do
    value =
      case Parser.parse_result(output) do
        {:ok, value, _} -> value
        _ -> String.trim(output)
      end

    with {:ok, parts} <- Balanced.split(value, separator) do
      Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
        case String.trim(part) do
          ^empty ->
            {:cont, {:ok, acc}}

          expression ->
            case parser.(expression) do
              nil -> {:halt, invalid_output()}
              conflict -> {:cont, {:ok, [conflict | acc]}}
            end
        end
      end)
      |> case do
        {:ok, conflicts} -> {:ok, conflicts |> Enum.reverse() |> Enum.uniq()}
        error -> error
      end
    else
      _ -> invalid_output()
    end
  end

  @doc false
  @spec arguments(String.t(), String.t()) :: {:ok, [String.t()]} | :error
  def arguments(expression, constructor) do
    prefix = constructor <> "("

    if String.starts_with?(expression, prefix) and String.ends_with?(expression, ")") do
      size = byte_size(expression) - byte_size(prefix) - 1

      case Balanced.split(binary_part(expression, byte_size(prefix), size)) do
        {:ok, parts} -> {:ok, Enum.map(parts, &String.trim/1)}
        :error -> :error
      end
    else
      :error
    end
  end

  @doc false
  @spec string(String.t()) :: {:ok, String.t()} | :error
  def string(value) do
    if Regex.match?(~r/\A"(?:\\.|[^"\\])*"\z/s, value) do
      {:ok, hd(Syntax.quoted_strings(value))}
    else
      :error
    end
  end

  @doc false
  @spec rule_id(String.t(), String.t(), pos_integer()) :: {:ok, String.t()} | :error
  def rule_id(rule, constructor, arity) do
    with {:ok, args} <- arguments(rule, constructor),
         true <- length(args) == arity do
      string(hd(args))
    else
      _ -> :error
    end
  end

  defp invalid_output,
    do: {:error, Error.new(:parse_error, "Unrecognized or incomplete conflict output")}
end
