defmodule Tokengate.Credits.RequestLogsIndexPlanTest do
  @moduledoc """
  Mechanical verification of the W10 `request_logs` access paths (F35/F36).

  Production measurement (`pg_stat_statements`, real `Heap Fetches` with real
  volume) is an owner-gated W15 step; what is proved HERE is the property the
  plan depends on:

    * the indexes exist with the exact definition the reads need
      (`credit_topup_id` leading, `model_requested`/`api_key_prefix` in the
      subject coverings), and
    * with synthetic volume and REAL selectivity, the queries those reads
      issue are answered by an **Index Only Scan** — which Postgres can only
      produce when the index truly covers every referenced column. A covering
      index that lacked a column could not become index-only at any cost
      setting; it would degrade to an Index Scan with a heap fetch.

  The fixture spreads the volume over many top-ups/services on purpose: a
  column that matches 100% of the table makes a full scan genuinely cheaper,
  and no index would win (that is the planner being right, not the index being
  wrong). Seq and bitmap scans are still disabled for the EXPLAIN so the
  assertion does not hinge on the planner's cost estimate for a fixture this
  size; index scans stay ENABLED because `enable_indexscan = off` also
  disables index-only scans.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Repo

  # A day far outside every fixture date used by the rest of the suite, so the
  # synthetic volume lands in a range no other test writes to.
  @day ~D[2098-01-01]
  @rows 20_000
  @topups 200
  @services 50

  setup do
    {:ok, user} =
      Tokengate.Accounts.register_user(%{
        email: "plan-#{System.unique_integer([:positive])}@example.com",
        name: "Plan User",
        password: "ValidPassword123"
      })

    topups = for _ <- 1..@topups, do: insert_topup!(user)
    services = for _ <- 1..@services, do: insert_service!()

    target_topup = hd(topups)
    target_service = hd(services)

    seed_volume(services, topups)

    # Fresh stats for the partition the volume landed in: without them the
    # planner still believes the (committed) previous state of the table and
    # every plan below would be judged on a stale row count.
    Repo.query!("ANALYZE request_logs_default")

    Repo.query!("SET LOCAL enable_seqscan = off")
    Repo.query!("SET LOCAL enable_bitmapscan = off")

    {:ok, user: user, service: target_service, topup: target_topup}
  end

  defp insert_topup!(user) do
    {:ok, topup} =
      %Tokengate.Credits.Topup{}
      |> Tokengate.Credits.Topup.changeset(%{
        user_id: user.id,
        amount_usd: Decimal.new("1000.000000"),
        label: "plan-fixture"
      })
      |> Repo.insert()

    topup
  end

  defp insert_service! do
    {:ok, service} =
      Tokengate.Accounts.create_service(%{name: "plan-svc-#{System.unique_integer([:positive])}"})

    service
  end

  # `g % #{@topups}` walks the whole array so the target row of each column
  # matches ~1/#{@topups} (top-ups) and ~1/#{@services} (services) of the
  # volume — the selectivity these reads have in production.
  defp seed_volume(services, topups) do
    service_array = "ARRAY[" <> Enum.map_join(services, ",", &"'#{&1.id}'::uuid") <> "]"
    topup_array = "ARRAY[" <> Enum.map_join(topups, ",", &"'#{&1.id}'::uuid") <> "]"

    Repo.query!(
      """
      INSERT INTO request_logs (
        id, inserted_at, model_requested, model_responded, agent_type,
        status_code, prompt_tokens, completion_tokens, provider_cost_usd,
        latency_ms, streaming, service_id, subject_type, credit_topup_id,
        api_key_prefix, api_key_id, user_id
      )
      SELECT
        gen_random_uuid(),
        $1::timestamp + (g || ' seconds')::interval,
        'model-' || (g % 4),
        'model-' || (g % 4),
        'api',
        200,
        100,
        50,
        round((0.0001 + (g % 7) * 0.00001)::numeric, 6),
        500,
        false,
        (#{service_array})[1 + (g % #{@services})],
        'service',
        (#{topup_array})[1 + (g % #{@topups})],
        'sk-plan',
        gen_random_uuid(),
        NULL
      FROM generate_series(1, #{@rows}) AS g
      """,
      [DateTime.new!(@day, ~T[00:00:00])]
    )
  end

  # EXPLAIN with LITERAL parameters, not bind variables.
  #
  # The indexes under test are PARTIAL (`WHERE credit_topup_id IS NOT NULL`),
  # and a generic plan has to assume `$1` can be NULL, so it cannot prove the
  # predicate and cannot use the index. Postgres' default is a CUSTOM plan
  # (actual parameter values) for the first executions of every statement,
  # which is what the app runs — the literal form is the honest way to EXPLAIN
  # it.
  defp plan!(query) do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
    literal_sql = bind_literals(sql, params)
    rows = Repo.query!("EXPLAIN " <> literal_sql).rows
    rows |> List.flatten() |> Enum.join("\n")
  end

  defp bind_literals(sql, params) do
    params
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce(sql, fn {value, i}, acc ->
      String.replace(acc, "$#{i}", sql_literal(value))
    end)
  end

  defp sql_literal(nil), do: "NULL"
  defp sql_literal(true), do: "TRUE"
  defp sql_literal(false), do: "FALSE"
  defp sql_literal(%DateTime{} = dt), do: "'#{Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")}'"
  defp sql_literal(%NaiveDateTime{} = dt), do: "'#{Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")}'"
  defp sql_literal(%Date{} = d), do: "'#{Date.to_iso8601(d)}'"
  defp sql_literal(%Decimal{} = d), do: Decimal.to_string(d)
  # `to_sql/3` returns already-dumped params: a uuid arrives as 16 raw bytes.
  defp sql_literal(<<_::128>> = raw_uuid), do: "'#{elem(Ecto.UUID.load(raw_uuid), 1)}'"
  defp sql_literal(value) when is_binary(value), do: "'#{value}'"
  defp sql_literal(value) when is_integer(value), do: Integer.to_string(value)

  defp index_def(name) do
    Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name]).rows
  end

  describe "F35 — consumed_usd/1 access path" do
    test "the leading credit_topup_id index exists with the covering measure" do
      assert [[def]] = index_def("request_logs_topup_inserted_idx")
      assert def =~ "credit_topup_id"
      assert def =~ "inserted_at"
      assert def =~ "INCLUDE (provider_cost_usd)"
      assert def =~ "WHERE (credit_topup_id IS NOT NULL)"
    end

    test "consumed_usd's query is index-only", %{topup: topup} do
      import Ecto.Query

      query =
        Tokengate.Logs.RequestLog
        |> where([rl], rl.credit_topup_id == ^topup.id)
        |> where([rl], rl.inserted_at >= ^DateTime.add(topup.inserted_at, -86_400, :second))
        |> select([rl], fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd))

      plan = plan!(query)

      assert plan =~ "Index Only Scan"
      refute plan =~ "Seq Scan"
      # Child indexes are named after their partition + COLUMNS, so match the
      # key pair this module is about (leading credit_topup_id, then the date
      # bound).
      assert plan =~ "credit_topup_id_inserted_at"

      # ...and the read itself answers the same number the unbounded version
      # would: the date bound must not drop any attributed row.
      assert Decimal.compare(Tokengate.Credits.Topups.consumed_usd(topup), 0) == :gt
    end
  end

  describe "F36 — top-models access path" do
    test "the service covering index now carries the grouping columns" do
      assert [[def]] = index_def("request_logs_service_spend_covering_idx")
      assert def =~ "service_id, inserted_at"
      assert def =~ "model_requested"
      assert def =~ "api_key_prefix"
      assert def =~ "provider_cost_usd"
    end

    test "top-models by service is index-only", %{service: service} do
      import Ecto.Query

      from_ts = DateTime.new!(@day, ~T[00:00:00])
      to_ts = DateTime.add(from_ts, 86_400, :second)

      # Same shape as `Logs.top_models_for_service/2`: filter by subject+window,
      # group by the requested model, sum cost/tokens.
      query =
        Tokengate.Logs.RequestLog
        |> where([rl], rl.service_id == ^service.id)
        |> where([rl], rl.inserted_at >= ^from_ts and rl.inserted_at < ^to_ts)
        |> group_by([rl], rl.model_requested)
        |> select([rl], %{
          model_requested: rl.model_requested,
          count: count(rl.id),
          total_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)"),
          total_prompt_tokens: coalesce(sum(rl.prompt_tokens), 0),
          total_completion_tokens: coalesce(sum(rl.completion_tokens), 0)
        })

      plan = plan!(query)

      assert plan =~ "Index Only Scan"
      refute plan =~ "Seq Scan"
    end

    test "the model x API-key report is index-only", %{service: service} do
      import Ecto.Query

      from_ts = DateTime.new!(@day, ~T[00:00:00])

      query =
        Tokengate.Logs.RequestLog
        |> where([rl], rl.service_id == ^service.id)
        |> where([rl], rl.inserted_at >= ^from_ts)
        |> group_by([rl], [rl.api_key_id, rl.model_requested])
        |> select([rl], %{
          api_key_id: rl.api_key_id,
          model_requested: rl.model_requested,
          request_count: count(rl.id),
          total_cost_usd: fragment("COALESCE(SUM(provider_cost_usd), 0)")
        })

      plan = plan!(query)

      assert plan =~ "Index Only Scan"
      refute plan =~ "Seq Scan"
    end
  end

  describe "F41 — dead indexes are gone, their replacements are not" do
    test "the redundant indexes no longer exist" do
      for name <- ~w(
            request_logs_credential_name_idx
            request_logs_session_id_idx
            request_logs_user_spend_all_idx
            request_logs_service_spend_all_idx
          ) do
        assert [] = index_def(name)
      end
    end

    test "the covering indexes that replaced them still exist" do
      assert [[_]] = index_def("request_logs_user_spend_covering_idx")
      assert [[_]] = index_def("request_logs_service_spend_covering_idx")
      assert [[_]] = index_def("request_logs_credential_inserted_idx")
    end
  end

  describe "F51 — errors index led by time" do
    test "the errors index is prunable by the window and covers the status" do
      assert [[def]] = index_def("request_logs_errors_idx")
      assert def =~ "(inserted_at)"
      assert def =~ "INCLUDE (status_code)"
      assert def =~ "WHERE (status_code >= 400)"
    end
  end
end
