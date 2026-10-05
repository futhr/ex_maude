defmodule ExMaude.Verification.CommandEcho do
  @moduledoc """
  Compares a search command echo while preserving lexical token identity.

  ASCII layout between tokens may change. Quoted strings and backquoted word
  spelling remain exact. This bounded matcher does not interpret terms, expand
  synonyms or normalize comments/mixfix/semantic pretty-printing. It starts no
  worker and creates no atoms. Completion parsing remains SearchRun's owner.
  """
  @layout [9, 10, 11, 12, 13, 32]
  @horizontal [9, 11, 12, 32]
  @punctuation [?(, ?), ?[, ?], ?{, ?}, ?,]
  @max_bytes 16_777_216

  @doc """
  Returns whether the output begins with the exact search tokens and terminator.

  Input must be UTF-8 without NUL, at most 16 MiB each. ASCII identifiers,
  unescaped punctuation and exact quoted strings are supported. Unterminated
  tokens and a non-line-ending suffix after the period return false.
  """
  @spec matches?(binary(), binary()) :: boolean()
  def matches?(raw, command)
      when is_binary(raw) and is_binary(command) and
             byte_size(raw) <= @max_bytes and byte_size(command) <= @max_bytes do
    with true <- valid?(raw) and valid?(command),
         {:ok, "search", expected} <- token(command),
         {:ok, "search", actual} <- token(raw) do
      compare(actual, expected, nil)
    else
      _ -> false
    end
  end

  def matches?(_, _), do: false

  defp valid?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)

  defp compare(actual, expected, previous) do
    case token(expected) do
      :end ->
        previous == "." and line_end?(actual)

      {:ok, value, rest} ->
        case token(actual) do
          {:ok, ^value, actual_rest} -> compare(actual_rest, rest, value)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp line_end?(<<char, rest::binary>>) when char in @horizontal, do: line_end?(rest)
  defp line_end?(<<>>), do: true
  defp line_end?(<<10, _::binary>>), do: true
  defp line_end?(<<13, 10, _::binary>>), do: true
  defp line_end?(_), do: false

  defp token(<<char, rest::binary>>) when char in @layout, do: token(rest)
  defp token(<<>>), do: :end
  defp token(<<char, rest::binary>>) when char in @punctuation, do: {:ok, <<char>>, rest}
  defp token(<<?", rest::binary>> = original), do: quoted(original, rest, 1)
  defp token(bytes), do: word(bytes, bytes, 0)

  defp word(original, <<>>, size), do: taken(original, <<>>, size)

  defp word(original, <<char, _::binary>> = rest, size)
       when char in @layout or char in @punctuation,
       do: taken(original, rest, size)

  defp word(original, <<?`, char, rest::binary>>, size)
       when char in 33..126 and char != ?` and char != ?",
       do: word(original, rest, size + 2)

  defp word(original, <<char, rest::binary>>, size)
       when char in 33..126 and char != ?` and char != ?",
       do: word(original, rest, size + 1)

  defp word(_, _, _), do: :error

  defp quoted(original, <<?\\, _, rest::binary>>, size),
    do: quoted(original, rest, size + 2)

  defp quoted(original, <<?", rest::binary>>, size), do: taken(original, rest, size + 1)
  defp quoted(original, <<_, rest::binary>>, size), do: quoted(original, rest, size + 1)
  defp quoted(_, <<>>, _), do: :error

  defp taken(_, _, 0), do: :error
  defp taken(original, rest, size), do: {:ok, binary_part(original, 0, size), rest}
end
