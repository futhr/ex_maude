defmodule ExMaude.Verification.BudgetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias ExMaude.Verification.Budget

  test "hand-prepared clocks do not reset the absolute deadline" do
    for {timeout, deadline, now, expected} <- [
          {50, -100, -160, {:ok, 50}},
          {50, -100, -110, {:ok, 10}},
          {50, -100, -101, {:ok, 1}},
          {50, -100, -100, {:error, :expired}},
          {50, -100, -90, {:error, :expired}},
          {50, :none, -100, {:ok, 50}},
          {100, 200, 0, {:ok, 100}},
          {100, 200, 199, {:ok, 1}}
        ] do
      assert Budget.remaining(timeout, deadline, now) == expected
    end
  end

  test "malformed values refuse" do
    for input <- [{0, 1, 0}, {-1, 1, 0}, {10, nil, 0}, {10, 1, nil}, {"10", 1, 0}] do
      {timeout, deadline, now} = input
      assert {:error, :invalid} = Budget.remaining(timeout, deadline, now)
    end
  end

  property "independent phase observations keep one fixed deadline" do
    if directory = System.get_env("BUDGET_EVIDENCE_DIR") do
      Code.ensure_loaded!(Budget)
      {Budget, bytes, _} = :code.get_object_code(Budget)
      File.write!(Path.join(directory, "producer.beam"), bytes, [:exclusive])
    end

    check all(
            now <- integer(-1_000_000..1_000_000),
            remaining <- integer(-2..100),
            timeout <- integer(1..100),
            delays <- list_of(integer(0..100), length: 3),
            max_runs: 300,
            max_shrinking_steps: 1024
          ) do
      deadline = now + remaining
      clocks = Enum.scan(delays, now, &+/2)

      expected =
        Enum.map(clocks, fn clock ->
          left = deadline - clock
          if left > 0, do: {:ok, min(left, timeout)}, else: {:error, :expired}
        end)

      input = %{
        timeout: timeout,
        deadline: deadline,
        now: now,
        delays: delays,
        clocks: clocks,
        expected: expected
      }

      name = record(input)
      actual = Enum.map(clocks, &Budget.remaining(timeout, deadline, &1))
      if name, do: File.write!(name <> "-actual.etf", :erlang.term_to_binary(actual))
      assert actual == expected
    end
  end

  defp record(input) do
    if directory = System.get_env("BUDGET_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      name = Path.join(directory, "budget-#{System.unique_integer([:positive])}")
      File.write!(name <> ".etf", :erlang.term_to_binary(input))
      name
    end
  end
end
