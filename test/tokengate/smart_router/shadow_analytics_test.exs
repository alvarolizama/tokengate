defmodule Tokengate.SmartRouter.ShadowAnalyticsTest do
  @moduledoc """
  Integration tests for the Shadow reads of `Tokengate.SmartRouter.Analytics`:
  `shadow_comparison/1`, `shadow_migrations/2` and `shadow_for_logs/1`.

  The fixtures live INSIDE today's UTC day and always key
  `request_inserted_at` to it, because that is the column the window is
  bounded on. Every money assertion is exact (`Decimal.equal?`): a delta that
  is silently clipped or re-rounded is exactly the bug these reads exist to
  prevent.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Analytics
  alias Tokengate.SmartRouter.Config
  alias Tokengate.SmartRouter.ShadowEvaluation

  # ---------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------

  defp at(hour, minute \\ 0, second \\ 0) do
    DateTime.new!(Date.utc_today(), Time.new!(hour, minute, second), "Etc/UTC")
  end

  defp window, do: [from: at(0), to: at(23, 59, 59)]

  defp money(value), do: Decimal.new(value)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp config_fixture(attrs \\ %{}) do
    attrs = Map.merge(%{name: unique("Shadow version")}, attrs)

    {:ok, config} =
      %Config{}
      |> Config.changeset(attrs)
      |> Repo.insert()

    config
  end

  @base_eval %{
    default_use_case_key: "fast",
    default_effort_tier: "medium",
    default_model_name: "model-default",
    use_case_key: "fast",
    effort_tier: "medium",
    model_name: "model-default",
    decision_source: "rule",
    decision_ms: 5,
    prompt_tokens_saved_est: 0,
    matches_default_model: true,
    matches_default_tier: true
  }

  defp eval_fixture(config, attrs) do
    attrs =
      @base_eval
      |> Map.merge(%{
        request_log_id: Ecto.UUID.generate(),
        request_inserted_at: at(10),
        shadow_config_id: config.id,
        shadow_config_name: config.name
      })
      |> Map.merge(attrs)

    %ShadowEvaluation{}
    |> ShadowEvaluation.changeset(attrs)
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------------
  # Window contract
  # ---------------------------------------------------------------------

  describe "window contract" do
    test "shadow_comparison/1 and shadow_migrations/2 raise ArgumentError without :from" do
      config = config_fixture()

      assert_raise ArgumentError, fn -> Analytics.shadow_comparison([]) end
      assert_raise ArgumentError, fn -> Analytics.shadow_migrations(config.id, []) end

      # String-keyed filters (query params) are held to the same contract.
      assert_raise ArgumentError, fn ->
        Analytics.shadow_comparison([{"shadow_config_id", config.id}])
      end
    end

    test "shadow_comparison/1 bounds on request_inserted_at" do
      shadow = config_fixture()

      eval_fixture(shadow, %{request_inserted_at: at(1)})
      eval_fixture(shadow, %{request_inserted_at: at(12)})

      assert [%{eval_count: 1}] = Analytics.shadow_comparison(from: at(11), to: at(13))
    end
  end

  # ---------------------------------------------------------------------
  # shadow_comparison/1
  # ---------------------------------------------------------------------

  describe "shadow_comparison/1" do
    test "computes agreement, tier shifts and the exact negative delta" do
      shadow = config_fixture(%{shadow_enabled: true})

      # Agreement on both axes, low → low, priced.
      eval_fixture(shadow, %{
        matches_default_model: true,
        matches_default_tier: true,
        default_effort_tier: "low",
        effort_tier: "low",
        default_served_cost_usd: money("1.000000"),
        estimated_served_cost_usd: money("0.400000"),
        decision_cost_usd: money("0.010000"),
        prompt_tokens_saved_est: 100
      })

      # Full disagreement, high → low (downgrade), priced.
      eval_fixture(shadow, %{
        matches_default_model: false,
        matches_default_tier: false,
        default_effort_tier: "high",
        effort_tier: "low",
        model_name: "model-cheap",
        default_served_cost_usd: money("2.000000"),
        estimated_served_cost_usd: money("1.000000"),
        decision_cost_usd: money("0.020000")
      })

      # Error: never a decision, never agreement, never money.
      eval_fixture(shadow, %{
        error_reason: "timeout",
        matches_default_model: false,
        matches_default_tier: false,
        default_effort_tier: "low",
        effort_tier: "high"
      })

      # Tier-only disagreement, medium → high (upgrade), priced, no classifier.
      eval_fixture(shadow, %{
        matches_default_model: true,
        matches_default_tier: false,
        default_effort_tier: "medium",
        effort_tier: "high",
        model_name: "model-big",
        default_served_cost_usd: money("0.500000"),
        estimated_served_cost_usd: money("0.900000"),
        prompt_tokens_saved_est: 50
      })

      assert [row] = Analytics.shadow_comparison(window())

      assert row.shadow_config_id == shadow.id
      assert row.shadow_config_name == shadow.name
      assert row.shadow_enabled == true
      refute row.archived

      # eval_count includes the error row; ok_count does not.
      assert row.eval_count == 4
      assert row.ok_count == 3
      assert row.error_count == 1

      assert row.matches_model_count == 2
      assert row.matches_tier_count == 1
      assert_in_delta 66.67, row.agreement_pct, 0.01
      assert_in_delta 33.33, row.tier_agreement_pct, 0.01

      assert row.downgrade_count == 1
      assert row.upgrade_count == 1

      assert row.priced_count == 3
      assert_in_delta 100.0, row.coverage_pct, 0.01

      # 1.0 + 2.0 + 0.5 / shadow 0.4 + 1.0 + 0.9 / decision 0.01 + 0.02.
      assert Decimal.equal?(row.default_served_cost_usd, money("3.500000"))
      assert Decimal.equal?(row.shadow_estimated_cost_usd, money("2.300000"))
      assert Decimal.equal?(row.shadow_decision_cost_usd, money("0.030000"))
      assert Decimal.equal?(row.shadow_total_cost_usd, money("2.330000"))

      # 2.33 - 3.50 = -1.17, reported as a saving, never clipped to zero.
      assert Decimal.equal?(row.estimated_delta_usd, money("-1.170000"))
      assert_in_delta(-33.43, row.estimated_delta_pct, 0.01)

      assert row.prompt_tokens_saved_est == 150
    end

    test "keeps a positive delta (the Shadow would have been more expensive)" do
      expensive = config_fixture(%{shadow_enabled: true, archived_at: at(9)})
      cheap = config_fixture()

      serving = Ecto.UUID.generate()
      previous = Ecto.UUID.generate()

      eval_fixture(expensive, %{
        default_config_id: serving,
        default_served_cost_usd: money("0.200000"),
        estimated_served_cost_usd: money("0.500000")
      })

      # A noise row on another version, filtered out by :shadow_config_id.
      eval_fixture(cheap, %{
        default_config_id: previous,
        default_served_cost_usd: money("9.000000"),
        estimated_served_cost_usd: money("1.000000")
      })

      assert [row] = Analytics.shadow_comparison(window() ++ [shadow_config_id: expensive.id])

      assert row.shadow_config_id == expensive.id
      assert row.archived
      assert Decimal.equal?(row.default_served_cost_usd, money("0.200000"))
      assert Decimal.equal?(row.estimated_delta_usd, money("0.300000"))
      assert_in_delta 150.0, row.estimated_delta_pct, 0.01

      # :default_config_id selects by who served the request.
      assert [cheap_row] =
               Analytics.shadow_comparison(window() ++ [default_config_id: previous])

      assert cheap_row.shadow_config_id == cheap.id

      # Without either filter both versions are reported.
      rows = Analytics.shadow_comparison(window())

      assert rows |> Enum.map(& &1.shadow_config_id) |> Enum.sort() ==
               Enum.sort([expensive.id, cheap.id])
    end

    test "reports priced coverage instead of pretending every row was priced" do
      shadow = config_fixture()

      eval_fixture(shadow, %{
        default_served_cost_usd: money("1.000000"),
        estimated_served_cost_usd: money("0.400000")
      })

      # Unpriced row: counted as an ok evaluation, excluded from the money
      # block, including its (large) Default cost.
      eval_fixture(shadow, %{
        default_served_cost_usd: money("5.000000"),
        estimated_served_cost_usd: nil
      })

      assert [row] = Analytics.shadow_comparison(window())

      assert row.eval_count == 2
      assert row.ok_count == 2
      assert row.priced_count == 1
      assert_in_delta 50.0, row.coverage_pct, 0.01

      assert Decimal.equal?(row.default_served_cost_usd, money("1.000000"))
      assert Decimal.equal?(row.shadow_estimated_cost_usd, money("0.400000"))
      assert Decimal.equal?(row.estimated_delta_usd, money("-0.600000"))
      assert_in_delta(-60.0, row.estimated_delta_pct, 0.01)
    end

    test "percentages are nil when nothing could be measured" do
      shadow = config_fixture()

      eval_fixture(shadow, %{
        error_reason: "decision_failed",
        matches_default_model: false,
        matches_default_tier: false,
        effort_tier: nil,
        estimated_served_cost_usd: nil,
        default_served_cost_usd: nil
      })

      assert [row] = Analytics.shadow_comparison(window())

      assert row.eval_count == 1
      assert row.ok_count == 0
      assert row.error_count == 1
      assert row.agreement_pct == nil
      assert row.tier_agreement_pct == nil
      assert row.coverage_pct == nil
      assert row.estimated_delta_pct == nil
      assert Decimal.equal?(row.estimated_delta_usd, money("0.000000"))
    end

    test "a classifier price on an unpriced or errored row never enters the delta" do
      shadow = config_fixture()

      # The only priced ok row: the Default cost, the estimated cost and the
      # classifier price all describe the SAME request.
      eval_fixture(shadow, %{
        default_served_cost_usd: money("1.000000"),
        estimated_served_cost_usd: money("0.400000"),
        decision_cost_usd: money("0.010000")
      })

      # Unpriced ok row WITH a classifier price: there is no Default cost to
      # compare it against, so it is outside the money block entirely.
      eval_fixture(shadow, %{
        default_served_cost_usd: money("5.000000"),
        estimated_served_cost_usd: nil,
        decision_cost_usd: money("0.500000")
      })

      # Error row with a decision price and a Default cost: never a decision.
      eval_fixture(shadow, %{
        error_reason: "timeout",
        matches_default_model: false,
        matches_default_tier: false,
        default_served_cost_usd: money("2.000000"),
        decision_cost_usd: money("0.700000")
      })

      assert [row] = Analytics.shadow_comparison(window())

      assert row.priced_count == 1
      assert Decimal.equal?(row.default_served_cost_usd, money("1.000000"))
      assert Decimal.equal?(row.shadow_estimated_cost_usd, money("0.400000"))
      # Only the priced ok row's classifier cost.
      assert Decimal.equal?(row.shadow_decision_cost_usd, money("0.010000"))
      assert Decimal.equal?(row.shadow_total_cost_usd, money("0.410000"))
      # 0.41 - 1.00, apple to apple.
      assert Decimal.equal?(row.estimated_delta_usd, money("-0.590000"))
    end
  end

  # ---------------------------------------------------------------------
  # shadow_migrations/2
  # ---------------------------------------------------------------------

  describe "shadow_migrations/2" do
    test "groups only the disagreeing rows, by migration, by impact" do
      shadow = config_fixture(%{shadow_enabled: true})
      other = config_fixture()

      # Same migration twice: medium → low, model-default → model-cheap.
      for _ <- 1..2 do
        eval_fixture(shadow, %{
          default_effort_tier: "medium",
          effort_tier: "low",
          default_model_name: "model-default",
          model_name: "model-cheap",
          matches_default_model: false,
          matches_default_tier: false,
          default_served_cost_usd: money("1.000000"),
          estimated_served_cost_usd: money("0.400000"),
          decision_cost_usd: money("0.010000")
        })
      end

      # Agreeing row: not a migration.
      eval_fixture(shadow, %{
        matches_default_model: true,
        matches_default_tier: true,
        estimated_served_cost_usd: money("9.000000")
      })

      # Error row: no decision, never a migration.
      eval_fixture(shadow, %{
        error_reason: "timeout",
        matches_default_model: false,
        matches_default_tier: false
      })

      # Another version's disagreement: belongs to that version only.
      eval_fixture(other, %{
        matches_default_model: false,
        matches_default_tier: false,
        estimated_served_cost_usd: money("0.100000")
      })

      # Different migration with the bigger per-row impact.
      eval_fixture(shadow, %{
        use_case_key: "writing",
        default_use_case_key: "fast",
        default_effort_tier: "high",
        effort_tier: "medium",
        default_model_name: "model-default",
        model_name: "model-mid",
        matches_default_model: false,
        matches_default_tier: false,
        default_served_cost_usd: money("3.000000"),
        estimated_served_cost_usd: money("1.000000")
      })

      assert [top, second] = Analytics.shadow_migrations(shadow.id, window())

      # Sorted by absolute impact: 2.00 ahead of 1.18.
      assert top.use_case_key == "writing"
      assert top.default_use_case_key == "fast"
      assert top.eval_count == 1
      assert Decimal.equal?(top.estimated_delta_usd, money("-2.000000"))

      assert second.use_case_key == "fast"
      assert second.default_model_name == "model-default"
      assert second.model_name == "model-cheap"
      assert second.default_effort_tier == "medium"
      assert second.effort_tier == "low"
      assert second.eval_count == 2
      assert second.priced_count == 2
      assert Decimal.equal?(second.default_served_cost_usd, money("2.000000"))
      assert Decimal.equal?(second.shadow_estimated_cost_usd, money("0.800000"))
      assert Decimal.equal?(second.shadow_decision_cost_usd, money("0.020000"))
      assert Decimal.equal?(second.shadow_total_cost_usd, money("0.820000"))
      assert Decimal.equal?(second.estimated_delta_usd, money("-1.180000"))
      assert_in_delta(-59.0, second.estimated_delta_pct, 0.01)
    end

    test "respects the window" do
      shadow = config_fixture()

      eval_fixture(shadow, %{
        request_inserted_at: at(1),
        matches_default_model: false,
        matches_default_tier: false
      })

      eval_fixture(shadow, %{
        request_inserted_at: at(12),
        matches_default_model: false,
        matches_default_tier: false
      })

      assert [row] = Analytics.shadow_migrations(shadow.id, from: at(11), to: at(13))
      assert row.eval_count == 1
    end

    test "an unpriced row contributes its volume but not its classifier cost" do
      shadow = config_fixture()

      eval_fixture(shadow, %{
        matches_default_model: false,
        matches_default_tier: false,
        default_served_cost_usd: money("1.000000"),
        estimated_served_cost_usd: money("0.400000"),
        decision_cost_usd: money("0.010000")
      })

      # Same migration, but unpriced: counted in `eval_count`, outside the
      # money block (no Default cost to compare, so no classifier price either).
      eval_fixture(shadow, %{
        matches_default_model: false,
        matches_default_tier: false,
        default_served_cost_usd: money("5.000000"),
        estimated_served_cost_usd: nil,
        decision_cost_usd: money("0.500000")
      })

      assert [row] = Analytics.shadow_migrations(shadow.id, window())

      assert row.eval_count == 2
      assert row.priced_count == 1
      assert Decimal.equal?(row.default_served_cost_usd, money("1.000000"))
      assert Decimal.equal?(row.shadow_estimated_cost_usd, money("0.400000"))
      assert Decimal.equal?(row.shadow_decision_cost_usd, money("0.010000"))
      assert Decimal.equal?(row.shadow_total_cost_usd, money("0.410000"))
      assert Decimal.equal?(row.estimated_delta_usd, money("-0.590000"))
    end
  end

  # ---------------------------------------------------------------------
  # shadow_for_logs/1
  # ---------------------------------------------------------------------

  describe "shadow_for_logs/1" do
    test "returns an empty map for no refs" do
      assert Analytics.shadow_for_logs([]) == %{}
    end

    test "maps several shadow evaluations per log, ordered by version name" do
      first = config_fixture(%{name: "A shadow version"})
      second = config_fixture(%{name: "B shadow version"})
      log_one = Ecto.UUID.generate()
      log_two = Ecto.UUID.generate()

      # Inserted out of order on purpose: the read sorts, not the insert.
      eval_fixture(second, %{request_log_id: log_one, shadow_config_name: second.name})
      eval_fixture(first, %{request_log_id: log_one, shadow_config_name: first.name})
      eval_fixture(first, %{request_log_id: log_two, shadow_config_name: first.name})

      result = Analytics.shadow_for_logs([log_one, log_two])

      assert result |> Map.keys() |> Enum.sort() == Enum.sort([log_one, log_two])

      assert result[log_one] |> Enum.map(& &1.shadow_config_name) == [
               "A shadow version",
               "B shadow version"
             ]

      assert result[log_two] |> Enum.map(& &1.shadow_config_name) == ["A shadow version"]
      assert Enum.all?(result[log_one], &match?(%ShadowEvaluation{}, &1))
    end

    test "honours the {log_id, inserted_at} pair to prune the index range" do
      shadow = config_fixture()
      log_id = Ecto.UUID.generate()

      eval_fixture(shadow, %{
        request_log_id: log_id,
        request_inserted_at: at(5),
        model_name: "early"
      })

      eval_fixture(shadow, %{
        request_log_id: log_id,
        request_inserted_at: at(15),
        model_name: "late"
      })

      # The pair pins [at(15), at(15)]: the earlier row of the same log is
      # outside the index range and must not come back.
      assert [row] = Analytics.shadow_for_logs([{log_id, at(15)}])[log_id]
      assert row.model_name == "late"
    end

    test "unknown ids return an empty map" do
      assert Analytics.shadow_for_logs([Ecto.UUID.generate()]) == %{}
    end
  end
end
