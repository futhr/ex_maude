defmodule ExMaude.ModelSemanticsTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  alias ExMaude.Backend.Port

  setup do
    worker =
      start_supervised!(
        {Port, maude_path: ExMaude.Binary.path(), preload_modules: [ExMaude.ai_rules_path()]}
      )

    %{worker: worker}
  end

  test "jurisdiction equality is reflexive including subjurisdictions", %{worker: worker} do
    for jurisdiction <- ~w(eu us cn ch uk ca au other de fr es it nl se fi dk pl be ie pt at) do
      assert {:ok, "true"} =
               Port.execute(
                 worker,
                 "reduce in JURISDICTION : eqJurisdiction(#{jurisdiction}, #{jurisdiction}) ."
               )
    end

    assert {:ok, "false"} =
             Port.execute(worker, "reduce in JURISDICTION : eqJurisdiction(de, fr) .")

    assert {:ok, "true"} =
             Port.execute(worker, "reduce in JURISDICTION : inJurisdictionSet(de, eu) .")
  end
end
