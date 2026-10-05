defmodule ExMaude.Verification.CommandEchoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ExMaude.Verification.CommandEcho

  @command "search [2,2] in ECHO : pair(2,3) =>* bad ."
  @echo "search [2, 2] in ECHO : pair(2, 3) =>* bad .\n\nNo solution.\nstates: 1\n"

  test "layout and punctuation preserve every submitted token" do
    assert CommandEcho.matches?(@echo, @command)
    assert CommandEcho.matches?(String.replace(@echo, " in ", "\n in\t"), @command)
    assert CommandEcho.matches?("\t" <> @echo, @command)
    assert CommandEcho.matches?(@command, @command)
  end

  test "changed words, bounds, modules, terms and output prefix refuse" do
    for {from, to} <- [
          {"[2, 2]", "[3, 2]"},
          {"ECHO", "FOREIGN"},
          {"pair(2, 3)", "pair(2, 4)"},
          {"bad", "good"},
          {"in ECHO", "inECHO"},
          {"=>*", "=>!"}
        ] do
      refute CommandEcho.matches?(String.replace(@echo, from, to), @command)
    end

    refute CommandEcho.matches?("unknown\n" <> @echo, @command)
    refute CommandEcho.matches?(String.replace(@echo, " .\n", " .evil\n"), @command)
    refute CommandEcho.matches?(String.replace(@echo, " .\n", " . extra\n"), @command)
  end

  test "quoted whitespace and escaped punctuation remain significant" do
    command = ~S|search [2,2] in ECHO : pair("a b,()", "c\"d") =>* "bad" .|
    echo = ~S|search [2, 2] in ECHO : pair("a b,()", "c\"d") =>* "bad" .|
    assert CommandEcho.matches?(echo <> "\n", command)
    refute CommandEcho.matches?(String.replace(echo, "a b", "ab") <> "\n", command)
    refute CommandEcho.matches?(String.replace(echo, ~S(c\"d), ~S(c d)) <> "\n", command)
    quoted = "search [2,2] in ECHO : foo`(a`,b`) =>* bad ."
    assert CommandEcho.matches?(String.replace(quoted, "[2,2]", "[2, 2]") <> "\n", quoted)
    refute CommandEcho.matches?(String.replace(quoted, "a`,b", "a,b") <> "\n", quoted)
  end

  test "invalid or unsupported bytes and unterminated commands refuse" do
    for command <- [
          "",
          "search x",
          "search \"broken .",
          "search foo`",
          "search a\"b .",
          "search " <> <<0>> <> " .",
          "search " <> <<255>> <> " ."
        ] do
      refute CommandEcho.matches?(command, command)
    end

    refute CommandEcho.matches?(String.duplicate(" ", 16_777_217), @command)
    refute CommandEcho.matches?(nil, @command)
  end

  property "independent tokens survive layout but detect changed values" do
    check all(
            a <- integer(0..100),
            b <- integer(0..100),
            bound <- integer(1..100),
            space <- member_of([" ", "\t", "\n", "\r\n", " \t"]),
            max_runs: 300
          ) do
      command = "search [#{bound},2] in ECHO : pair(#{a},#{b}) =>* bad ."

      tokens = [
        "search",
        "[",
        "#{bound}",
        ",",
        "2",
        "]",
        "in",
        "ECHO",
        ":",
        "pair",
        "(",
        "#{a}",
        ",",
        "#{b}",
        ")",
        "=>*",
        "bad",
        "."
      ]

      echo = Enum.join(tokens, space) <> "\nNo solution.\nstates: 1\n"

      changed =
        Enum.join(List.replace_at(tokens, 13, Integer.to_string(b + 1)), space) <>
          "\nNo solution.\nstates: 1\n"

      name =
        record(%{
          command: command,
          echo: echo,
          changed: changed,
          a: a,
          b: b,
          bound: bound,
          space: space
        })

      actual = {CommandEcho.matches?(echo, command), CommandEcho.matches?(changed, command)}
      if name, do: File.write!(name <> "-actual.etf", :erlang.term_to_binary(actual))
      assert actual == {true, false}
    end
  end

  defp record(input) do
    if directory = System.get_env("ECHO_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      name = Path.join(directory, "echo-#{System.unique_integer([:positive])}")
      File.write!(name <> ".etf", :erlang.term_to_binary(input))
      name
    end
  end
end
