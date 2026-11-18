defmodule Tokengate.Metrics.StatsQueriesClosedWindowTest do
  # async: false — flips the global rollup flag and populates whole-time buckets.
  use Tokengate.DataCase, async: false

  import Ecto.Query

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.{Rollup, StatsQueries}
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Periods
  alias Tokengate.Providers
  alias Tokengate.Repo

  # `yesterday` is the only CLOSED window in the canonical set (today/week/30d
  # end at `now`). The original spec pinned `last_month`; that builder left the
  # canonical vocabulary in W1 (still documented in `Periods`, no longer
  # offered anywhere), so the same contract is pinned here on the canonical
  # closed day: an aggregate must never add the rows that follow the window,
  # and that holds for BOTH halves of a hybrid read — the rollup side is where
  # the old `from`-only reads silently summed the next month.
  test "a closed canonical window (yesterday) respects the upper bound on both halves" do
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

    %{from: from, to: to} = Periods.period_bounds("yesterday", "Etc/UTC")
    inside = DateTime.add(from, 12 * 3600, :second)
    # First hour AFTER the closed window: aggregated into the rollup on
    # purpose, so the assertions below prove the read bound — not a missing
    # aggregate — keeps it out.
    outside = DateTime.add(to, 3600, :second)

    for {at, count} <- [{inside, 1}, {outside, 10}] do
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

    # Rollup covers the whole closed day AND the hour after it.
    {:ok, _} = HourlyAggregate.aggregate_hours(from, to)

    {:ok, _} =
      HourlyAggregate.aggregate_hours(to, DateTime.add(to, 2 * 3600, :second))

    # The out-of-window traffic really is in the rollup (10 requests), so a
    # reader that ignored `to` on the rollup side would return 11.
    assert rollup_requests_from(outside) == 10

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

  defp rollup_requests_from(hour) do
    Repo.one(
      from(m in Tokengate.Metrics.RequestMetricsHourly,
        where: m.hour_utc == ^hour,
        select: fragment("COALESCE(SUM(?), 0)::bigint", m.request_count)
      )
    )
  end
end
