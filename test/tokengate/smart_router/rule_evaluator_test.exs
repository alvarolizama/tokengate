defmodule Tokengate.SmartRouter.RuleEvaluatorTest do
  use ExUnit.Case, async: true

  alias Tokengate.SmartRouter.RequestAnalyzer
  alias Tokengate.SmartRouter.RuleEvaluator

  defp analysis(payload, context \\ %{}), do: RequestAnalyzer.analyze(payload, context)

  defp rule(attrs) do
    Map.merge(
      %{
        name: "rule",
        priority: 100,
        enabled: true,
        action: "restrict_use_cases",
        target_use_case_keys: ["fast"],
        match_conditions: %{}
      },
      attrs
    )
  end

  test "every condition must hold" do
    result =
      RuleEvaluator.evaluate(
        [
          rule(%{
            name: "agents with tools",
            action: "force_use_case",
            target_use_case_keys: ["coding_implement"],
            match_conditions: %{"has_tools" => true, "min_tokens" => 10}
          })
        ],
        analysis(%{
          "tools" => [%{"type" => "function", "function" => %{"name" => "x"}}],
          "messages" => [%{"role" => "user", "content" => String.duplicate("a", 200)}]
        })
      )

    assert result.force == "coding_implement"
    assert result.forced_by == "agents with tools"
  end

  test "a condition that does not hold keeps the rule out" do
    result =
      RuleEvaluator.evaluate(
        [
          rule(%{
            name: "vision",
            action: "force_use_case",
            target_use_case_keys: ["vision_extraction"],
            match_conditions: %{"has_vision" => true}
          })
        ],
        analysis(%{"messages" => [%{"role" => "user", "content" => "text only"}]})
      )

    assert result.force == nil
    assert result.matched == []
  end

  test "an empty condition set is a catch-all" do
    result =
      RuleEvaluator.evaluate(
        [rule(%{name: "catch all", action: "force_use_case", target_use_case_keys: ["fast"]})],
        analysis(%{})
      )

    assert result.force == "fast"
  end

  test "force_use_case is terminal: the first matching force wins" do
    result =
      RuleEvaluator.evaluate(
        [
          rule(%{
            name: "second",
            priority: 20,
            action: "force_use_case",
            target_use_case_keys: ["writing"]
          }),
          rule(%{
            name: "first",
            priority: 10,
            action: "force_use_case",
            target_use_case_keys: ["coding_implement"]
          })
        ],
        analysis(%{})
      )

    assert result.force == "coding_implement"
    assert result.matched == ["first"]
  end

  test "restrict_use_cases accumulates as an intersection" do
    result =
      RuleEvaluator.evaluate(
        [
          rule(%{
            name: "a",
            priority: 1,
            action: "restrict_use_cases",
            target_use_case_keys: ~w(fast writing coding_implement)
          }),
          rule(%{
            name: "b",
            priority: 2,
            action: "restrict_use_cases",
            target_use_case_keys: ~w(writing coding_implement)
          }),
          rule(%{
            name: "c",
            priority: 3,
            action: "restrict_use_cases",
            target_use_case_keys: ~w(coding_implement research)
          })
        ],
        analysis(%{})
      )

    assert result.restrict == ["coding_implement"]
    assert result.matched == ~w(a b c)
  end

  test "content_regex only sees the last user message" do
    matching =
      RuleEvaluator.evaluate(
        [
          rule(%{
            name: "finance",
            action: "force_use_case",
            target_use_case_keys: ["data_heavy_finance"],
            match_conditions: %{"content_regex" => "conciliaci[oó]n"}
          })
        ],
        analysis(%{
          "messages" => [
            %{"role" => "system", "content" => "conciliación"},
            %{"role" => "user", "content" => "suma esto"}
          ]
        })
      )

    assert matching.force == nil

    direct =
      RuleEvaluator.evaluate(
        [
          rule(%{
            name: "finance",
            action: "force_use_case",
            target_use_case_keys: ["data_heavy_finance"],
            match_conditions: %{"content_regex" => "conciliaci[oó]n"}
          })
        ],
        analysis(%{"messages" => [%{"role" => "user", "content" => "haz la conciliación"}]})
      )

    assert direct.force == "data_heavy_finance"
  end

  test "agent, group and service ids match only when present" do
    conditions = %{"agent_types" => ["codex"], "group_ids" => ["g1"], "service_ids" => ["s1"]}

    matched =
      RuleEvaluator.evaluate(
        [rule(%{name: "scoped", match_conditions: conditions})],
        analysis(%{}, %{agent_type: "codex", group_id: "g1", service_id: "s1"})
      )

    assert matched.matched == ["scoped"]

    refute_unmatched =
      RuleEvaluator.evaluate(
        [rule(%{name: "scoped", match_conditions: conditions})],
        analysis(%{})
      )

    assert refute_unmatched.matched == []
  end

  test "unknown conditions never match" do
    result =
      RuleEvaluator.evaluate(
        [rule(%{name: "typo", match_conditions: %{"has_tool" => true}})],
        analysis(%{"tools" => [%{"type" => "function"}]})
      )

    assert result.matched == []
  end
end
