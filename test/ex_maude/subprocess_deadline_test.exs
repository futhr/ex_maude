defmodule ExMaude.SubprocessDeadlineTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @tag :tmp_dir
  test "expired absolute deadline refuses before native creation", %{tmp_dir: directory} do
    pid_file = Path.join(directory, "native.pid")
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, :timeout} =
             ExMaude.Subprocess.run(
               System.find_executable("sh"),
               ["-c", ~s(printf '%s' "$$" > "$1"), "child", pid_file],
               5000,
               100,
               deadline
             )

    refute File.exists?(pid_file)
  end

  test "malformed deadline refuses without launching an executable" do
    for deadline <- [nil, 1.0, "1", :unsupported] do
      assert {:error, :invalid_deadline} =
               ExMaude.Subprocess.run("/missing", [], 1000, 100, deadline)
    end
  end
end
