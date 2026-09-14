defmodule Tokengate.Metrics.StatsQueriesTest do
  @moduledoc """
  Parity tests for the hybrid stats reads (`StatsQueries`): with the rollup
  populated for the old part of the window and raw rows in the fresh tail,
  the hybrid result must match the pure-raw aggregation.
  """

  # async: false — these tests flip the global :stats_rollup hybrid flag.
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Metrics.StatsQueries

  @base_attrs %{
    model_requested: "gpt-4",
    status_code: 200,
    prompt_tokens: 100,
    completion_tokens: 50,
    cost_usd: Decimal.new("0.800000"),
    latency_ms: 500,
    streaming: false
  }

  defp group_member_fixture do
    {:ok, group} =
      Accounts.create_group(%{name: "SQ Group #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "sq-#{System.unique_integer([:positive])}@example.com",
        name: "SQ User",
        password: "ValidPassword123"
      })

    {:ok, member} =
      Accounts.create_group_member(%{group_id: group.id, user_id: user.id})

    {member, group}
  end

  defp log_request(member_id, inserted_at, overrides \\ %{}) do
    attrs =
      @base_attrs
      |> Map.merge(Map.new(overrides))
      |> Map.put(:group_member_id, member_id)
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _} = Logs.log_request(attrs)
    :ok
  end

  defp hours_ago(h),
    do: DateTime.add(DateTime.utc_now(), -h * 3600, :second) |> DateTime.truncate(:second)

  describe "hybrid parity (rollup populated, tail raw)" do
    setup do
      original = Application.get_env(:tokengate, :stats_rollup)
      Application.put_env(:tokengate, :stats_rollup, hybrid: true)
      on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, original) end)
      :ok
    end

    test "summary matches the raw summary over the same window" do
      {member, _group} = group_member_fixture()

      # Old part (in the rollup): 3 logs 48h ago. Tail: 2 logs minutes ago.
      log_request(member.id, hours_ago(48), cost_usd: Decimal.new("1.000000"))
      log_request(member.id, hours_ago(47), cost_usd: Decimal.new("2.000000"))
      log_request(member.id, hours_ago(46), cost_usd: Decimal.new("3.000000"))
      log_request(member.id, hours_ago(1), cost_usd: Decimal.new("0.500000"))
      log_request(member.id, hours_ago(1), cost_usd: Decimal.new("0.250000"))

      # Populate the rollup up to the tail cutoff (now - 3h), like the
      # worker would have done on its last tick.
      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
      assert hybrid.total_prompt_tokens == raw.total_prompt_tokens
      assert hybrid.total_completion_tokens == raw.total_completion_tokens
    end

    test "breakdown_by_model merges rollup and tail rows" do
      {member, _group} = group_member_fixture()

      log_request(member.id, hours_ago(48), model_requested: "gpt-4")
      log_request(member.id, hours_ago(48), model_requested: "gpt-4")
      log_request(member.id, hours_ago(1), model_requested: "gpt-4")
      log_request(member.id, hours_ago(1), model_requested: "claude-3")

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.breakdown_by_model(nil, from: from, to: to)
      raw = Tokengate.Metrics.Rollup.breakdown_by_model(nil, from: from, to: to)

      by_model = fn rows -> Map.new(rows, fn r -> {r.model_name, r} end) end

      h = by_model.(hybrid)
      r = by_model.(raw)

      assert Map.keys(h) == Map.keys(r)

      for name <- Map.keys(h) do
        assert h[name].request_count == r[name].request_count
        assert Decimal.compare(h[name].cost_usd, r[name].cost_usd) == :eq
      end
    end
  end

  describe "hybrid off (test env default)" do
    test "answers raw" do
      {member, _group} = group_member_fixture()
      log_request(member.id, hours_ago(48))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      # test env sets hybrid: false — this must equal the raw summary
      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == raw.request_count
    end
  end
end
