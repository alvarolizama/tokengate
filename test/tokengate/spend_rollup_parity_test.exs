defmodule Tokengate.SpendRollupParityTest do
  @moduledoc """
  Parity tests for the hybrid per-user spend reads (`Logs.total_spend_by_user/0`
  and `Budgets.spend_by_member_ids/2`): rollup populated for the closed hours,
  raw rows in the fresh tail, and the merged result must equal the pure-raw
  aggregation over the same window.
  """

  # async: false — these tests flip the global :stats_rollup hybrid flag.
  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Budgets
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup.HourlyAggregate

  @base_attrs %{
    model_requested: "gpt-4",
    status_code: 200,
    prompt_tokens: 100,
    completion_tokens: 50,
    latency_ms: 500,
    streaming: false
  }

  defp member_fixture do
    {:ok, group} =
      Accounts.create_group(%{name: "SP Group #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "sp-#{System.unique_integer([:positive])}@example.com",
        name: "SP User",
        password: "ValidPassword123"
      })

    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
    {member, user}
  end

  defp log_request(member, user, inserted_at, cost) do
    attrs =
      @base_attrs
      |> Map.put(:group_member_id, member.id)
      |> Map.put(:user_id, user.id)
      |> Map.put(:provider_cost_usd, Decimal.new(cost))
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _} = Logs.log_request(attrs)
    :ok
  end

  defp hours_ago(h),
    do: DateTime.add(DateTime.utc_now(), -h * 3600, :second) |> DateTime.truncate(:second)

  describe "with the rollup populated for the closed hours" do
    setup do
      original = Application.get_env(:tokengate, :stats_rollup)
      Application.put_env(:tokengate, :stats_rollup, hybrid: true)
      on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, original) end)
      :ok
    end

    test "total_spend_by_user/0 matches the raw lifetime sum" do
      {member, user} = member_fixture()

      # Closed part (goes to the rollup) and fresh tail (stays raw).
      log_request(member, user, hours_ago(48), "1.000000")
      log_request(member, user, hours_ago(47), "2.500000")
      log_request(member, user, hours_ago(1), "0.250000")
      log_request(member, user, hours_ago(1), "0.125000")

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      hybrid = Logs.total_spend_by_user()
      raw = raw_total_spend_by_user()

      assert Decimal.compare(hybrid[user.id], raw[user.id]) == :eq
    end

    test "spend_by_member_ids/2 (monthly window) matches the raw sum" do
      {member, user} = member_fixture()

      log_request(member, user, hours_ago(50), "3.000000")
      log_request(member, user, hours_ago(1), "1.500000")

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = Tokengate.Periods.start_of_month_utc("Etc/UTC")
      hybrid = Budgets.spend_by_member_ids([member.id])
      raw = raw_member_spend(member.id, from)

      assert Decimal.compare(hybrid.monthly[member.id], raw) == :eq
    end
  end

  # Raw reference queries: the same aggregates the hybrid replaced, unfiltered
  # by the rollup.
  defp raw_total_spend_by_user do
    import Ecto.Query

    Tokengate.Logs.RequestLog
    |> where([rl], not is_nil(rl.user_id))
    |> group_by([rl], rl.user_id)
    |> select([rl], {rl.user_id, fragment("COALESCE(SUM(?::numeric), 0)", rl.provider_cost_usd)})
    |> Tokengate.Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
  end

  defp raw_member_spend(member_id, from) do
    import Ecto.Query

    Tokengate.Logs.RequestLog
    |> where([rl], rl.group_member_id == ^member_id and rl.inserted_at >= ^from)
    |> select([rl], fragment("COALESCE(SUM(?::numeric), 0)", rl.provider_cost_usd))
    |> Tokengate.Repo.one()
    |> to_string()
    |> Decimal.new()
  end
end
