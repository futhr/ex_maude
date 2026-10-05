defmodule ExMaude.Verification.VersionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ExMaude.Verification.Version

  test "independent hand labels preserve interior bytes" do
    for {bytes, expected} <- [
          {"  Maude 3.5.1\r\n", "Maude 3.5.1"},
          {"\tfixture -1 α\n build 2 \n", "fixture -1 α\n build 2"},
          {"\u00A0opaque\u00A0", "\u00A0opaque\u00A0"},
          {String.duplicate("a", 65_536), String.duplicate("a", 65_536)}
        ] do
      assert {:ok, ^expected} = Version.decode(bytes)
    end

    for bytes <- ["", " \t\r\n", <<255>>, "version" <> <<0>>] do
      assert {:error, %ExMaude.Error{type: :parse_error}} = Version.decode(bytes)
    end
  end

  test "malformed arguments and oversized labels refuse" do
    for bytes <- [nil, 3, [:version]],
        do: assert({:error, %ExMaude.Error{type: :validation}} = Version.decode(bytes))

    assert {:error, %ExMaude.Error{type: :response_too_large}} =
             Version.decode(String.duplicate("a", 65_537))
  end

  property "generated labels refuse missing or corrupted identity" do
    check all(
            number <- integer(0..100),
            kind <- member_of([:version, :blank]),
            before <- list_of(member_of([32, 9, 10, 13]), max_length: 4),
            after_layout <- list_of(member_of([32, 9, 10, 13]), max_length: 4),
            max_runs: 300
          ) do
      label = if kind == :version, do: "Maude #{number}.0 μ\nbuild #{number}", else: ""
      bytes = IO.iodata_to_binary([before, label, after_layout])
      expected = if kind == :version, do: {:ok, label}, else: :parse_error

      input = %{
        number: number,
        kind: kind,
        before: before,
        after_layout: after_layout,
        bytes: bytes,
        expected: expected
      }

      record = record(input)

      actual =
        {Version.decode(bytes), Version.decode(bytes <> <<0>>), Version.decode(bytes <> <<255>>)}

      retain(record, actual)
      {decoded, nul, utf8} = actual
      if kind == :version, do: assert(decoded == expected), else: assert_parse(decoded)
      assert_parse(nul)
      assert_parse(utf8)
    end
  end

  defp assert_parse(actual), do: assert({:error, %ExMaude.Error{type: :parse_error}} = actual)

  defp record(input) do
    if directory = System.get_env("VERSION_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      path = Path.join(directory, "version-#{System.unique_integer([:positive])}")
      File.write!(path <> ".etf", :erlang.term_to_binary(input))
      path
    end
  end

  defp retain(nil, _), do: :ok

  defp retain(path, actual),
    do: File.write!(path <> "-actual.etf", :erlang.term_to_binary(actual))
end
