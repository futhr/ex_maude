defmodule ExMaude.ValidationRegressionTest do
  use ExUnit.Case, async: true

  @rules [
    {ExMaude.IoT, %{id: "r", thing_id: "device", trigger: {:always}, actions: []}},
    {ExMaude.AI, %{id: "r", agent_id: {"tenant", "agent"}, trigger: {:always}, invocations: []}}
  ]

  test "both domains accept the depth limit and reject the next level" do
    for {domain, rule} <- @rules do
      at_limit = Enum.reduce(1..10, {:always}, fn _, child -> {:not, child} end)
      assert :ok = domain.validate_rule(%{rule | trigger: at_limit})
      assert {:error, _} = domain.validate_rule(%{rule | trigger: {:not, at_limit}})
    end
  end

  test "nil is rejected in either branch of compound triggers" do
    for {domain, rule} <- @rules,
        operator <- [:and, :or],
        trigger <- [
          {operator, nil, {:always}},
          {operator, {:always}, nil}
        ] do
      assert {:error, _} = domain.validate_rule(%{rule | trigger: trigger})
    end
  end

  test "omitted priority uses the default but explicit nil is invalid" do
    for {domain, rule} <- @rules do
      assert :ok = domain.validate_rule(rule)
      assert :ok = domain.validate_rule(Map.put(rule, :priority, 0))
      assert {:error, _} = domain.validate_rule(Map.put(rule, :priority, nil))
    end
  end

  test "nonadjacent duplicate IDs are rejected without rejecting distinct IDs" do
    for {domain, rule} <- @rules do
      second = %{rule | id: "second"}
      assert :ok = domain.validate_rules([rule, second])
      assert {:error, _} = domain.validate_rules([rule, second, rule])
    end
  end

  test "control bytes and malformed UTF-8 cannot become rule identifiers" do
    for {domain, rule} <- @rules, bad <- ["x\0y", "x\ty", "x\ny", "x\ry", <<127>>, <<255>>] do
      assert {:error, _} = domain.validate_rule(%{rule | id: bad})
    end

    for {domain, rule} <- @rules do
      assert :ok = domain.validate_rule(%{rule | id: "räksmörgås"})
    end
  end

  test "argument keys remain valid and distinct after conversion from atoms" do
    invocation = fn args -> {:invoke_tool, "tool", args, "capability", :eu} end
    validator = ExMaude.AI.Validator
    assert :ok = validator.validate_invocation(invocation.(%{x: 1, y: 2}))
    assert {:error, _} = validator.validate_invocation(invocation.(%{:x => 1, "x" => 2}))
    assert {:error, _} = validator.validate_invocation(invocation.(%{"bad\nkey" => 1}))
    assert {:error, _} = validator.validate_invocation(invocation.(%{"bad\nkey": 1}))
  end
end
