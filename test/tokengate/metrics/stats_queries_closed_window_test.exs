defmodule Tokengate.Metrics.StatsQueriesClosedWindowTest do
  # async: false — flips the global rollup flag and populates whole-time buckets.
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.{Rollup, StatsQueries}
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Periods
  alias Tokengate.Providers

  test "last_month hybrid aggregates respect the closed upper bound" do
    original = Application.get_env(:tokengate, :stats_rollup)
    Application.put_env(:tokengate, :stats_rollup, hybrid: true)
    on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, original) end)

    {:ok, group} =
      Accounts.create_group(%{name: "Closed #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "closed-#{System.unique_integer([:positive])}@example.com",
        name: "Closed User",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

    {:ok, model} =
      Providers.create_model(%{
        "name" => "closed-#{System.unique_integer([:positive])}",
        "context_window" => 128_000
      })

    {:ok, provider} =
      Providers.create_provider(%{
        "name" => "closed-#{System.unique_integer([:positive])}",
        "base_url" => "http://closed-window.test"
      })

    %{from: from, to: to} = Periods.period_bounds("last_month", "Etc/UTC")
    inside = DateTime.add(from, 12 * 3600, :second)

    for {at, count} <- [
          {inside, 1},
          # Older than the raw tail and inside the current calendar month:
          # it winds up in the rollup, but MUST stay outside `last_month`.
          {DateTime.add(DateTime.utc_now(), -6 * 3600, :second), 10}
        ] do
      for _ <- 1..count do
        {:ok, _} =
          Logs.log_request(%{
            group_member_id: member.id,
            model_id: model.id,
            model_requested: model.name,
            provider_id: provider.id,
            inserted_at: at,
            status_code: 200,
            prompt_tokens: 100,
            completion_tokens: 50,
            cost_usd: Decimal.new("1.000000"),
            latency_ms: 500,
            streaming: false
          })
      end
    end

    {:ok, _} =
      HourlyAggregate.aggregate_hours(
        %{from | minute: 0, second: 0, microsecond: {0, 0}},
        DateTime.add(DateTime.utc_now(), -3 * 3600, :second)
      )

    opts = [from: from, to: to, timezone: "Etc/UTC"]
    hybrid_summary = StatsQueries.summary(opts)
    raw_summary = Logs.cost_summary(%{from: from, to: to})

    assert hybrid_summary.request_count == 1
    assert hybrid_summary.request_count == raw_summary.request_count
    assert Decimal.compare(hybrid_summary.total_cost_usd, raw_summary.total_cost_usd) == :eq

    for {hybrid, raw} <- [
          {StatsQueries.breakdown_by_model(nil, opts), Rollup.breakdown_by_model(nil, opts)},
          {StatsQueries.breakdown_by_member(nil, opts), Rollup.breakdown_by_member(nil, opts)},
          {StatsQueries.breakdown_by_group(opts), Rollup.breakdown_by_group(opts)}
        ] do
      assert Enum.sum(Enum.map(hybrid, & &1.request_count)) == 1

      assert Enum.sum(Enum.map(hybrid, & &1.request_count)) ==
               Enum.sum(Enum.map(raw, & &1.request_count))
    end

    hybrid_profile = StatsQueries.usage_by_hour_of_day_by_provider(opts)
    raw_profile = Rollup.usage_by_hour_of_day_by_provider(opts)

    assert Enum.sum(Enum.map(hybrid_profile, & &1.total_requests)) ==
             Enum.sum(Enum.map(raw_profile, & &1.total_requests))

    hybrid_stacked = StatsQueries.usage_by_model_provider_stacked(opts)
    raw_stacked = Rollup.usage_by_model_provider_stacked(opts)

    assert Enum.sum(Enum.map(hybrid_stacked, & &1.total_requests)) ==
             Enum.sum(Enum.map(raw_stacked, & &1.total_requests))

    hybrid_hours = StatsQueries.busiest_hours(nil, opts)
    raw_hours = Rollup.busiest_hours(nil, opts)

    assert Enum.sum(Enum.map(hybrid_hours, & &1.request_count)) ==
             Enum.sum(Enum.map(raw_hours, & &1.request_count))
  end
end
