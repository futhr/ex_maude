defmodule ExMaude.WorkflowCacheTest do
  use ExUnit.Case, async: true

  @workflows Path.expand("../../.github/workflows", __DIR__)

  for workflow <- ["ci.yml", "publish.yml"] do
    @workflow workflow
    test "#{workflow} caches invalidate when either installed runtime patch changes" do
      templates =
        @workflows
        |> Path.join(@workflow)
        |> File.read!()
        |> String.split(~r/\n  [a-z][a-z0-9_-]*:\n/)
        |> Enum.flat_map(&cache_templates/1)

      assert templates != []

      for {job, template} <- templates do
        original = render(template, "29.0.4", "1.20.4")
        refute original == render(template, "29.0.5", "1.20.4"), template
        refute original == render(template, "29.0.4", "1.20.5"), template
        assert job =~ ~r/^\s+id: setup-beam$/m
      end
    end
  end

  defp cache_templates(job) do
    if String.contains?(job, "actions/cache@") do
      ~r/^[\t ]+(?:key|restore-keys):[\t ]*([^\n]+(?:\n[\t ]+\$\{\{[^\n]+)*)/m
      |> Regex.scan(job, capture: :all_but_first)
      |> Enum.flat_map(fn [value] -> String.split(value, "\n", trim: true) end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "|"))
      |> Enum.map(&{job, &1})
    else
      []
    end
  end

  defp render(template, otp, elixir) do
    template
    |> String.replace("${{ steps.setup-beam.outputs.otp-version }}", otp)
    |> String.replace("${{ steps.setup-beam.outputs.elixir-version }}", elixir)
  end
end
