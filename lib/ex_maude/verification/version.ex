defmodule ExMaude.Verification.Version do
  @moduledoc """
  Decodes a bounded opaque executable-version label without starting resources.

  This preserves measured label bytes after stripping ASCII edge layout. It
  does not enforce semantic versioning or authenticate the selected executable.
  """
  alias ExMaude.Error
  @max_bytes 65_536
  @layout [32, 9, 10, 13]

  @doc """
  Decodes nonempty UTF-8 version bytes with no NUL and at most 65536 bytes.

  Leading/trailing ASCII space, tab, CR and LF are removed. Interior bytes and
  other Unicode characters remain exact. Missing/malformed labels return a
  parse error; nonbinary arguments return validation errors; excess bytes
  return response-too-large. This function performs no I/O or configuration.
  """
  @spec decode(binary()) :: {:ok, String.t()} | {:error, Error.t()}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes,
    do: {:error, Error.response_too_large(@max_bytes)}

  def decode(bytes) when is_binary(bytes) do
    with true <- String.valid?(bytes) and not String.contains?(bytes, <<0>>),
         label = trim_right(trim_left(bytes)),
         true <- label != "" do
      {:ok, label}
    else
      _ -> {:error, Error.new(:parse_error, "version label is missing or malformed")}
    end
  end

  def decode(_), do: {:error, Error.new(:validation, "version bytes must be binary")}

  defp trim_left(<<character, rest::binary>>) when character in @layout, do: trim_left(rest)
  defp trim_left(bytes), do: bytes
  defp trim_right(<<>>), do: <<>>

  defp trim_right(bytes) do
    size = byte_size(bytes)

    if :binary.at(bytes, size - 1) in @layout,
      do: trim_right(binary_part(bytes, 0, size - 1)),
      else: bytes
  end
end
