defmodule ExMaude.ModelScalingTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  test "pairwise models grow quadratically in rewrite count" do
    for {encoder, path, module, operation, rule} <- [
          {ExMaude.IoT.Encoder, ExMaude.iot_rules_path(), "CONFLICT-DETECTOR",
           "detectAllConflicts",
           fn i -> %{id: "r#{i}", thing_id: "d#{i}", trigger: {:always}, actions: []} end},
          {ExMaude.AI.Encoder, ExMaude.ai_rules_path(), "AI-CONFLICT-DETECTOR",
           "detectAllPairConflicts",
           fn i ->
             %{id: "r#{i}", agent_id: {"t", "a#{i}"}, trigger: {:always}, invocations: []}
           end}
        ] do
      [small, large] =
        for count <- [8, 16] do
          {:ok, rules} = encoder.encode_rules(Enum.map(1..count, rule))

          file =
            Path.join(
              System.tmp_dir!(),
              "model-scale-#{System.unique_integer([:positive])}.maude"
            )

          File.write!(
            file,
            "load #{ExMaude.Syntax.encode_string(path)}\nreduce in #{module} : #{operation}(#{rules}) .\nquit\n"
          )

          try do
            {output, 0} =
              System.cmd(ExMaude.Binary.path(), ["-no-banner", "-no-wrap", file],
                stderr_to_stdout: true
              )

            refute output =~ "Warning:"
            [_, rewrites] = Regex.run(~r/rewrites: (\d+)/, output)
            String.to_integer(rewrites)
          after
            File.rm(file)
          end
        end

      assert large < small * 5
    end
  end
end
