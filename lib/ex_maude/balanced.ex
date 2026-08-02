defmodule ExMaude.Balanced do
  @moduledoc false

  @doc false
  @spec extract(String.t(), String.t()) :: [String.t()]
  def extract(input, marker) when is_binary(input) and is_binary(marker) and marker != "" do
    do_extract(input, marker, [])
  end

  defp do_extract(input, marker, acc) do
    case :binary.match(input, marker) do
      :nomatch ->
        Enum.reverse(acc)

      {start, marker_length} ->
        candidate = binary_part(input, start, byte_size(input) - start)

        case through_matching_paren(candidate, 0, 0, false, false) do
          {:ok, expression, remaining} ->
            do_extract(remaining, marker, [expression | acc])

          :error ->
            continue_after_failed_match(input, marker, acc, start + marker_length)
        end
    end
  end

  defp continue_after_failed_match(input, marker, acc, next_start) do
    remaining_length = byte_size(input) - next_start

    if remaining_length > 0 do
      do_extract(binary_part(input, next_start, remaining_length), marker, acc)
    else
      Enum.reverse(acc)
    end
  end

  defp through_matching_paren(input, depth, position, true, true)
       when position < byte_size(input) do
    through_matching_paren(input, depth, position + 1, true, false)
  end

  defp through_matching_paren(input, depth, position, true, false)
       when position < byte_size(input) do
    case :binary.at(input, position) do
      ?\\ -> through_matching_paren(input, depth, position + 1, true, true)
      ?" -> through_matching_paren(input, depth, position + 1, false, false)
      _ -> through_matching_paren(input, depth, position + 1, true, false)
    end
  end

  defp through_matching_paren(input, depth, position, false, false)
       when position < byte_size(input) do
    case :binary.at(input, position) do
      ?" ->
        through_matching_paren(input, depth, position + 1, true, false)

      ?( ->
        through_matching_paren(input, depth + 1, position + 1, false, false)

      ?) when depth == 1 ->
        expression = binary_part(input, 0, position + 1)
        remaining_length = byte_size(input) - position - 1

        remaining =
          if remaining_length > 0,
            do: binary_part(input, position + 1, remaining_length),
            else: ""

        {:ok, expression, remaining}

      ?) when depth > 1 ->
        through_matching_paren(input, depth - 1, position + 1, false, false)

      _ ->
        through_matching_paren(input, depth, position + 1, false, false)
    end
  end

  defp through_matching_paren(_, _, _, _, _), do: :error
end
