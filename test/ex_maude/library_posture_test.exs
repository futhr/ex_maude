defmodule ExMaude.LibraryPostureTest do
  @moduledoc false

  use ExUnit.Case, async: true

  test "the Hex library has no automatic application callback" do
    assert Application.spec(:ex_maude, :mod) == []
    refute Code.ensure_loaded?(ExMaude.Application)
  end

  test "callers receive a configurable pool child spec" do
    {id, {:poolboy, :start_link, [pool_config, _]}, _, _, _, _} =
      ExMaude.Pool.child_spec(name: :formal_verification, pool_size: 2)

    assert id == :formal_verification
    assert pool_config[:name] == {:local, :formal_verification}
    assert pool_config[:size] == 2
  end
end
