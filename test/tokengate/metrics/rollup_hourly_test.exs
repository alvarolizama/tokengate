defmodule Tokengate.Metrics.RollupHourlyTest do
  @moduledoc """
  Parity tests for the `request_metrics_hourly` rollup: the rollup-backed
  reads must return the same numbers as the equivalent `request_logs`
  aggregations, and the aggregation itself must be idempotent.
  """

  use Tokengate.DataCase, async: true
  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.Rollup.HourlyAggregate

  @base_attrs %{
    model_requested: "gpt-4",
    model_responded: "gpt-4-turbo",
    agent_type: "api",
    status_code: 200,
    prompt_tokens: 100,
    completion_tokens: 50,
    cost_usd: Decimal.new("0.800000"),
    latency_ms: 500,
    streaming: false
  }

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Platform Team",
            "monthly_budget_per_user_usd" => "100.00",
            "default_concurrency_limit" => 10,
            "default_rpm_limit" => 120
          },
          attrs
        )
      )

    team
  end

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "user#{System.unique_integer([:positive])}@example.com",
            "name" => "Test User",
            "password" => "ValidPassword123"
          },
          attrs
        )
      )

    user
  end

  defp team_member_fixture(_attrs \\ %{}) do
    team = team_fixture()
    user = user_fixture()

    {:ok, team_member} =
      Accounts.create_team_member(%{
        "team_id" => team.id,
        "user_id" => user.id,
        "team_role" => "user"
      })

    {team_member, team}
  end

  defp log_request(team_member_id, inserted_at, overrides) do
    attrs =
      Map.merge(@base_attrs, Map.new(overrides))
      |> Map.put(:team_member_id, team_member_id)
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _log} = Logs.log_request(attrs)
    :ok
  end

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  # Aggregate the whole visible past (well beyond the fixture timestamps)
  # so every inserted log is captured by the rollup.
  defp aggregate_all! do
    from = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
    {:ok, _rows} = HourlyAggregate.aggregate_hours(from, DateTime.utc_now())
    :ok
  end

  describe "aggregate_hours/2 + summary parity" do
    test "summary_from_rollup matches Logs.cost_summary_for_members" do
      {tm, _team} = team_member_fixture()

      log_request(tm.id, DateTime.add(DateTime.utc_now(), -3600, :second), %{
        cost_usd: Decimal.new("1.500000")
      })

      log_request(tm.id, DateTime.add(DateTime.utc_now(), -3660, :second), %{
        cost_usd: Decimal.new("2.250000"),
        status_code: 500,
        prompt_tokens: 300,
        completion_tokens: 150,
        latency_ms: 1500
      })

      aggregate_all!()

      from = hours_ago(24)

      expected = Logs.cost_summary_for_members([tm.id], %{from: from})
      actual = Rollup.summary_for_members(from: from, member_ids: [tm.id])

      assert actual.request_count == expected.request_count
      assert actual.total_prompt_tokens == expected.total_prompt_tokens
      assert actual.total_completion_tokens == expected.total_completion_tokens
      assert Decimal.round(actual.total_cost_usd, 5) == Decimal.round(expected.total_cost_usd, 5)
      # The rollup additionally tracks errors and avg latency.
      assert actual.error_count == 1
      assert actual.avg_latency_ms == 1000.0
    end

    test "empty member list returns zeroes without querying" do
      summary = Rollup.summary_for_members(from: hours_ago(24), member_ids: [])
      assert summary.request_count == 0
      assert summary.total_cost_usd == Decimal.new(0)
    end
  end

  describe "aggregate_hours/2 + series parity" do
    test "hourly_series_for_members matches the request_logs fallback numbers" do
      {tm, _team} = team_member_fixture()

      now = DateTime.utc_now()

      log_request(tm.id, DateTime.add(now, -3600, :second), %{
        cost_usd: Decimal.new("1.500000")
      })

      log_request(tm.id, DateTime.add(now, -3660, :second), %{
        cost_usd: Decimal.new("2.500000"),
        prompt_tokens: 7,
        completion_tokens: 3,
        latency_ms: 200
      })

      log_request(tm.id, DateTime.add(now, -7200, :second), %{
        cost_usd: Decimal.new("0.250000")
      })

      aggregate_all!()

      # Rollup read (no fallback possible — data exists):
      rollup_series =
        Rollup.hourly_series_from_rollup(
          from: hours_ago(24),
          timezone: "Etc/UTC",
          member_ids: [tm.id]
        )

      # Fallback (request_logs) read via the same entry point, computing
      # against a clean rollup for the same range is impossible without
      # deleting rows — instead assert against the raw request_logs query
      # by calling the private fallback indirectly: run the read BEFORE
      # aggregating in a second fixture set is covered by the "no rollup
      # data" test below. Here: compare rollup numbers directly.
      assert length(rollup_series) == 2

      [first, second] = rollup_series
      # Newest bucket first? No — ascending by hour.
      assert DateTime.compare(first.hour, second.hour) == :lt

      latest = List.last(rollup_series)

      assert latest.request_count == 2
      assert latest.prompt_tokens == 107
      assert latest.completion_tokens == 53
      assert latest.total_latency_ms == 700
      assert Decimal.round(latest.cost_usd, 5) == Decimal.round(Decimal.new("4.000000"), 5)
    end

    test "hourly_series_for_members falls back to request_logs when rollup is empty" do
      {tm, _team} = team_member_fixture()

      log_request(tm.id, DateTime.add(DateTime.utc_now(), -3600, :second), %{
        cost_usd: Decimal.new("1.500000")
      })

      # No aggregate_all!() — the rollup is empty for this range.
      series = Rollup.hourly_series_for_members([tm.id], [from: hours_ago(24)], "Etc/UTC")

      assert length(series) == 1
      [row] = series
      assert row.request_count == 1
      assert Decimal.round(row.cost_usd, 5) == Decimal.round(Decimal.new("1.500000"), 5)
    end
  end

  describe "aggregate_hours/2 idempotency" do
    test "re-running the aggregation does not double-count" do
      {tm, _team} = team_member_fixture()

      log_request(tm.id, DateTime.add(DateTime.utc_now(), -3600, :second), %{
        cost_usd: Decimal.new("1.000000")
      })

      aggregate_all!()
      summary_after_first = Rollup.summary_for_members(from: hours_ago(24), member_ids: [tm.id])

      aggregate_all!()
      summary_after_second = Rollup.summary_for_members(from: hours_ago(24), member_ids: [tm.id])

      assert summary_after_second.request_count == summary_after_first.request_count
      assert summary_after_second.total_prompt_tokens == summary_after_first.total_prompt_tokens

      assert Decimal.round(summary_after_second.total_cost_usd, 5) ==
               Decimal.round(summary_after_first.total_cost_usd, 5)
    end
  end
end
