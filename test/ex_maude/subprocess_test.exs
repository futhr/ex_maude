defmodule ExMaude.SubprocessTest do
  use ExUnit.Case, async: true

  test "collects output and exit status" do
    assert {:ok, "hello", 3} =
             ExMaude.Subprocess.run(
               System.find_executable("sh"),
               ["-c", "printf hello; exit 3"],
               1000,
               100
             )
  end

  test "terminates a child that never exits" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             ExMaude.Subprocess.run(
               Path.expand("test/support/fake_blocked_input.sh"),
               [],
               50,
               100
             )

    assert System.monotonic_time(:millisecond) - started < 1000
  end

  test "caps command output" do
    assert {:error, :output_too_large} =
             ExMaude.Subprocess.run(System.find_executable("sh"), ["-c", "printf 12345"], 1000, 4)
  end
end
