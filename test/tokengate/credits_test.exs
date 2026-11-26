defmodule Tokengate.CreditsTest do
  use Tokengate.DataCase, async: false

  alias Tokengate.{Accounts, Credits, Logs}
  alias Tokengate.Credits.Topups
  alias Tokengate.Metrics.{ConsumptionCounter, ConsumptionCounters, DashboardCache}
  alias Tokengate.Repo

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

  # Counts the Ecto queries per source table while `fun` runs.
  # Telemetry handlers are node-global, so queries issued by another process
  # (the LiveView) are counted too.
  defp count_queries(sources, fun) do
    counters = Map.new(sources, &{&1, :counters.new(1, [:atomics])})
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tokengate, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        case Map.fetch(counters, metadata[:source]) do
          {:ok, counter} -> :counters.add(counter, 1, 1)
          :error -> :ok
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    Map.new(counters, fn {source, counter} -> {source, :counters.get(counter, 1)} end)
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

      sources = ~w(request_logs consumption_counters)
      cold = count_queries(sources, fn -> Credits.user_credit_aggregates() end)
      warm = count_queries(sources, fn -> Credits.user_credit_aggregates() end)

      # Cold: el agregado sale de los contadores durables (un renglón por
      # usuario y día) — una sola pasada para el total y la parte debitada al
      # límite (`SUM(... FILTER ...)`), más el `populated?/0` que elige la ruta.
      # `request_logs` NO se escanea: eso es lo que dejó de costar el mes entero
      # cada 5 segundos. Warm: nada contra la base.
      assert cold == %{"request_logs" => 0, "consumption_counters" => 2}
      assert warm == %{"request_logs" => 0, "consumption_counters" => 0}
    end

    test "summaries/1 resolves spend and limit_spend in one aggregate query" do
      {_user, member} = member_with_limit("100.00")
      spend(member, "1.00")

      counts =
        count_queries(~w(request_logs consumption_counters), fn -> Credits.summaries([member]) end)

      # El total y la parte debitada al límite salen de la misma GROUP BY, y la
      # fuente son los contadores: ninguna partición de request_logs se toca.
      assert counts == %{"request_logs" => 0, "consumption_counters" => 2}
    end

    test "falls back to the raw aggregate when the counters are empty" do
      {_user, member} = member_with_limit("100.00")
      spend(member, "1.00")

      # Contadores vacíos (deploy sin backfill): la lectura vuelve a los logs.
      Repo.delete_all(ConsumptionCounter)
      refute ConsumptionCounters.populated?()

      counts =
        count_queries(~w(request_logs consumption_counters), fn -> Credits.summaries([member]) end)

      # `populated?/0` + el agregado crudo sobre request_logs.
      assert counts == %{"request_logs" => 1, "consumption_counters" => 1}
    end
  end
end
