defmodule ExMaude.AITest do
  @moduledoc false

  use ExMaude.MaudeCase

  alias ExMaude.AI

  doctest ExMaude.AI

  describe "validate_rule/1 (delegate)" do
    test "passes through to validator" do
      rule = %{
        id: "r1",
        agent_id: {"acme", "ag1"},
        trigger: {:always},
        invocations: []
      }

      assert :ok = AI.validate_rule(rule)
    end

    test "surfaces validator errors" do
      assert {:error, _} = AI.validate_rule(%{})
    end
  end

  describe "validate_rules/1 (delegate)" do
    test "returns ok for valid set" do
      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      ]

      assert :ok = AI.validate_rules(rules)
    end

    test "returns failures map for invalid set" do
      rules = [%{id: "r1"}]
      assert {:error, %{"r1" => _}} = AI.validate_rules(rules)
    end
  end

  describe "ai_rules_path/0" do
    test "returns a path under priv/" do
      path = ExMaude.ai_rules_path()
      assert is_binary(path)
      assert String.ends_with?(path, "ai-rules.maude")
    end

    test "the bundled module exists" do
      path = ExMaude.ai_rules_path()
      assert File.exists?(path), "expected ai-rules.maude at #{path}"
    end
  end

  describe "detect_conflicts/2 (integration)" do
    @describetag :integration

    test "no conflicts returns empty list", %{maude_available: true} do
      rules = [
        %{
          id: "harmless",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: []
        }
      ]

      assert {:ok, []} = AI.detect_conflicts(rules)
    end

    test "detects sovereignty violation when invocation jurisdiction outside allowed",
         %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "search", %{}, "internet_access", :us}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu, :ch])

      assert Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end

    test "detects approval-gate bypass on high_impact invocation without prior gate",
         %{maude_available: true} do
      rules = [
        %{
          id: "auto-dose",
          agent_id: {"acme", "controller"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "dose", %{}, "high_impact", :eu}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu])

      assert Enum.any?(conflicts, &(&1.type == :approval_gate_bypass))
    end

    test "approval-gate bypass clears when require_approval precedes high_impact",
         %{maude_available: true} do
      rules = [
        %{
          id: "approve-then-dose",
          agent_id: {"acme", "controller"},
          trigger: {:always},
          invocations: [
            {:require_approval, "dosing_high_delta"},
            {:invoke_tool, "dose", %{}, "high_impact", :eu}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_conflicts(rules, jurisdictions: [:eu])

      refute Enum.any?(conflicts, &(&1.type == :approval_gate_bypass))
    end
  end

  describe "telemetry" do
    @describetag :integration

    test "emits start and stop events", %{maude_available: true} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "ai-test-#{inspect(ref)}",
        [
          [:ex_maude, :ai, :detect_conflicts, :start],
          [:ex_maude, :ai, :detect_conflicts, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      rules = [
        %{
          id: "r1",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: []
        }
      ]

      {:ok, _} = AI.detect_conflicts(rules)

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start], _,
                      %{template: :ai_rules}},
                     2_000

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :stop], _, metadata},
                     5_000

      assert metadata.template == :ai_rules
      assert metadata.result == :ok

      :telemetry.detach("ai-test-#{inspect(ref)}")
    end

    test "start event measurements include rule_count", %{maude_available: true} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "ai-test-count-#{inspect(ref)}",
        [:ex_maude, :ai, :detect_conflicts, :start],
        fn event, measurements, _, _ ->
          send(test_pid, {ref, event, measurements})
        end,
        nil
      )

      rules = [
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []},
        %{id: "r2", agent_id: {"a", "c"}, trigger: {:always}, invocations: []},
        %{id: "r3", agent_id: {"a", "d"}, trigger: {:always}, invocations: []}
      ]

      {:ok, _} = AI.detect_conflicts(rules)

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start],
                      %{rule_count: 3, system_time: _}},
                     2_000

      :telemetry.detach("ai-test-count-#{inspect(ref)}")
    end
  end

  describe "detect_pair_conflicts/2 (integration)" do
    @describetag :integration

    test "returns empty list for harmless rule set", %{maude_available: true} do
      rules = [
        %{
          id: "harmless",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: []
        }
      ]

      assert {:ok, []} = AI.detect_pair_conflicts(rules)
    end

    test "skips single-rule sovereignty conflict", %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "search", %{}, "internet_access", :us}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_pair_conflicts(rules)

      refute Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end
  end

  describe "detect_single_rule_conflicts/2 (integration)" do
    @describetag :integration

    test "returns sovereignty violation when invocation jurisdiction outside allowed",
         %{maude_available: true} do
      rules = [
        %{
          id: "us-routing",
          agent_id: {"acme", "ag1"},
          trigger: {:always},
          invocations: [
            {:invoke_tool, "search", %{}, "internet_access", :us}
          ]
        }
      ]

      {:ok, conflicts} = AI.detect_single_rule_conflicts(rules, jurisdictions: [:eu])
      assert Enum.any?(conflicts, &(&1.type == :sovereignty_violation))
    end
  end

  describe "telemetry (unit-level, no Maude required)" do
    test "start event fires before any backend call" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "ai-unit-start-#{inspect(ref)}",
        [:ex_maude, :ai, :detect_conflicts, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {ref, event, measurements, metadata})
        end,
        nil
      )

      # Issue a call. We don't care whether it succeeds — only that the
      # :start event arrives before any potential failure.
      AI.detect_conflicts([
        %{id: "r1", agent_id: {"a", "b"}, trigger: {:always}, invocations: []}
      ])

      assert_receive {^ref, [:ex_maude, :ai, :detect_conflicts, :start],
                      %{rule_count: 1, system_time: _}, %{template: :ai_rules}},
                     2_000

      :telemetry.detach("ai-unit-start-#{inspect(ref)}")
    end
  end
end
