defmodule Tokengate.CreditsTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Credits, Logs}
  alias Tokengate.Credits.Topups
  alias Tokengate.Metrics.DashboardCache

  defp unique, do: System.unique_integer([:positive])

  defp register_user do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "credits-#{u}@example.com",
        name: "Credits #{u}",
        password: "password-secret-#{u}1",
        global_role: "user"
      })

    user
  end

  # User inside a limit profile (the budget the credit column reads) plus the
  # membership row the summaries are keyed by.
  defp member_with_limit(limit_usd) do
    user = register_user()

    {:ok, group} =
      Accounts.create_group(%{
        name: "Credits Group #{unique()}",
        monthly_spend_limit_usd: limit_usd
      })

    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})

    {user, member}
  end

  defp spend(member, usd, opts \\ []) do
    {:ok, _} =
      Logs.log_request(
        [
          group_member_id: member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new(usd)
        ]
        |> Keyword.merge(opts)
        |> Map.new()
      )
  end

  # Counts the Ecto queries that touch `request_logs` while `fun` runs.
  # Telemetry handlers are node-global, so queries issued by another process
  # (the LiveView) are counted too.
  defp count_request_log_queries(fun) do
    counter = :counters.new(1, [:atomics])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tokengate, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "request_logs", do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  defp assert_decimal(a, b, label) do
    assert Decimal.equal?(a, b), "#{label}: expected #{inspect(b)}, got #{inspect(a)}"
  end

  describe "user_credit_aggregates/0" do
    test "returns whole-table spend, limit spend and top-ups per user" do
      {user, member} = member_with_limit("100.00")
      {other_user, other_member} = member_with_limit("50.00")

      # 30 debited to the limit, 4 paid with a top-up: `spend` sees both,
      # `limit_spend` only the first (that is what consumes the monthly cap).
      spend(member, "30.00")
      {:ok, topup} = Topups.create(%{"user_id" => user.id, "amount_usd" => "10.00"})
      spend(member, "4.00", credit_topup_id: topup.id)
      spend(other_member, "12.50")

      aggregates = Credits.user_credit_aggregates()

      assert_decimal(Map.fetch!(aggregates.spend, user.id), Decimal.new("34.00"), "spend")
      assert_decimal(Map.fetch!(aggregates.spend, other_user.id), Decimal.new("12.50"), "spend")
      assert_decimal(Map.fetch!(aggregates.limit_spend, user.id), Decimal.new("30.00"), "limit")

      # The top-up map goes through `Topups` (draining order + consumed credit).
      entry = Map.fetch!(aggregates.topups, user.id)
      assert_decimal(entry.remaining_topup_usd, Decimal.new("6.00"), "remaining top-up")
      assert [%{consumed_usd: consumed}] = entry.topups
      assert_decimal(consumed, Decimal.new("4.00"), "top-up consumed")
      refute Map.has_key?(aggregates.topups, other_user.id)
    end

    test "cached summaries carry exactly the eager values" do
      {user, member} = member_with_limit("100.00")
      spend(member, "30.00")
      {:ok, topup} = Topups.create(%{"user_id" => user.id, "amount_usd" => "10.00"})
      spend(member, "4.00", credit_topup_id: topup.id)

      eager = Credits.summaries([member])
      cached = Credits.summaries([member], cached: true)

      assert Map.keys(eager) == Map.keys(cached)

      for {id, eager_summary} <- eager do
        cached_summary = Map.fetch!(cached, id)

        assert_decimal(cached_summary.spend_usd, eager_summary.spend_usd, "spend_usd")

        assert_decimal(
          cached_summary.limit_spend_usd,
          eager_summary.limit_spend_usd,
          "limit_spend_usd"
        )

        assert_decimal(
          cached_summary.remaining_limit_usd,
          eager_summary.remaining_limit_usd,
          "remaining_limit_usd"
        )

        assert_decimal(
          cached_summary.remaining_topup_usd,
          eager_summary.remaining_topup_usd,
          "remaining_topup_usd"
        )

        assert_decimal(cached_summary.limit_usd, eager_summary.limit_usd, "limit_usd")
        assert cached_summary.unlimited? == eager_summary.unlimited?
        assert cached_summary.has_path? == eager_summary.has_path?
        assert length(cached_summary.topups) == length(eager_summary.topups)

        for {cached_row, eager_row} <- Enum.zip(cached_summary.topups, eager_summary.topups) do
          assert cached_row.topup.id == eager_row.topup.id
          assert_decimal(cached_row.remaining_usd, eager_row.remaining_usd, "top-up remaining")
        end
      end
    end

    test "is computed once per TTL window" do
      {_user, member} = member_with_limit("100.00")
      spend(member, "1.00")

      DashboardCache.invalidate_all()

      cold = count_request_log_queries(fn -> Credits.user_credit_aggregates() end)
      warm = count_request_log_queries(fn -> Credits.user_credit_aggregates() end)

      # Cold: the two spend aggregates over request_logs (the top-up
      # consumption read only runs when live top-ups exist). Warm: nothing
      # against request_logs at all.
      assert cold == 2
      assert warm == 0
    end
  end
end
