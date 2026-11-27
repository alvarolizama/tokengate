defmodule Tokengate.Metrics.FinopsAndFixesTest do
  @moduledoc """
  Covers the S1/F1 slice: the rollup/stats fixes (router_decision exclusion,
  `subject_type` consistency, O(n) merges, deterministic ties, weighted summary
  merges, one shared TPS formula) and the shared FinOps aggregates in
  `Tokengate.Metrics.Rollup`.

  `async: false` — the hybrid tests flip the global `:stats_rollup` flag and
  populate whole-hour rollup buckets.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Metrics.Rollup.HourlyAggregate
  alias Tokengate.Metrics.StatsQueries
  alias Tokengate.Providers

  # ---------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------

  defp unique, do: System.unique_integer([:positive])

  defp user_fixture(name \\ "Finops User") do
    {:ok, user} =
      Accounts.register_user(%{
        email: "finops-#{unique()}@example.com",
        name: name,
        password: "ValidPassword123"
      })

    user
  end

  defp member_fixture do
    {:ok, group} = Accounts.create_group(%{name: "Finops Group #{unique()}"})
    user = user_fixture()
    {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user.id})
    {member, user, group}
  end

  defp service_fixture(name) do
    {:ok, service} = Accounts.create_service(%{name: name})
    service
  end

  defp api_key_fixture(service, label, status \\ "active") do
    {:ok, key} =
      Accounts.create_api_key(%{
        subject_type: "service",
        service_id: service.id,
        label: label,
        key_hash: "hash-#{unique()}",
        key_prefix: "sk-#{unique()}",
        status: status
      })

    key
  end

  defp model_fixture(name) do
    {:ok, model} =
      Providers.create_model(%{
        "name" => name || "finops-model-#{unique()}",
        "context_window" => 128_000
      })

    model
  end

  defp provider_fixture(name) do
    {:ok, provider} =
      Providers.create_provider(%{
        "name" => name || "finops-provider-#{unique()}",
        "base_url" => "http://finops-#{unique()}.test"
      })

    provider
  end

  defp model_provider_fixture(model, provider) do
    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "key-#{unique()}",
        api_key_encrypted: "sk-test-#{unique()}",
        status: "active"
      })

    {:ok, mp} =
      Providers.create_model_provider(%{
        model_id: model.id,
        credential_id: credential.id,
        provider_model: "route-#{unique()}",
        enabled: true
      })

    mp
  end

  defp log!(inserted_at, attrs) do
    {:ok, log} =
      attrs
      |> Map.new()
      |> Map.put_new(:model_requested, "gpt-4")
      |> Map.put(:inserted_at, inserted_at)
      |> Logs.log_request()

    log
  end

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  defp at(day, time), do: DateTime.new!(day, time, "Etc/UTC")

  # Buckets come back from `date_trunc` with microseconds; compare instants.
  defp same_instant?(left, right),
    do: DateTime.compare(DateTime.truncate(left, :second), right) == :eq

  defp enable_hybrid! do
    original = Application.get_env(:tokengate, :stats_rollup)
    Application.put_env(:tokengate, :stats_rollup, hybrid: true)
    on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, original) end)
    :ok
  end

  defp dec!(value), do: Decimal.new(value)

  defp assert_decimal!(expected, actual) do
    assert Decimal.compare(dec!(expected), actual) == :eq,
           "expected #{expected}, got #{inspect(actual)}"
  end

  # ---------------------------------------------------------------------
  # The shared dataset used by every FinOps test.
  #
  # day1 = today-3, day2 = today-2. Served rows only, plus ONE
  # `router_decision` row (the classifier's own billed call) that must never
  # appear as served traffic.
  # ---------------------------------------------------------------------
  defp seed_finops! do
    {member_a, user_a, _} = member_fixture()
    {member_b, user_b, _} = member_fixture()

    service_1 = service_fixture("Finops Service One")
    service_2 = service_fixture("Finops Service Two")
    key_1 = api_key_fixture(service_1, "svc-one-primary")
    key_2 = api_key_fixture(service_2, "svc-two-revoked", "revoked")

    model_a = model_fixture("finops-model-a")
    model_b = model_fixture("finops-model-b")
    provider = provider_fixture("Finops Provider")
    model_provider = model_provider_fixture(model_a, provider)

    day1 = Date.add(Date.utc_today(), -3)
    day2 = Date.add(Date.utc_today(), -2)

    # 1 — user A, chat, recovered fallback, prompt savings.
    log!(at(day1, ~T[10:05:00]),
      group_member_id: member_a.id,
      user_id: user_a.id,
      subject_type: "user",
      model_id: model_a.id,
      provider_id: provider.id,
      request_type: "chat",
      status_code: 200,
      provider_status_code: 500,
      prompt_tokens: 100,
      completion_tokens: 50,
      cache_read_tokens: 10,
      cache_creation_tokens: 5,
      cost_usd: dec!("1.000000"),
      latency_ms: 500,
      prompt_tokens_saved_est: 7
    )

    # 2 — user B, chat, upstream error.
    log!(at(day1, ~T[11:15:00]),
      group_member_id: member_b.id,
      user_id: user_b.id,
      subject_type: "user",
      request_type: "chat",
      status_code: 500,
      prompt_tokens: 200,
      completion_tokens: 100,
      cost_usd: dec!("2.000000"),
      latency_ms: 1000
    )

    # 3 — service 1 / key 1, embeddings, reasoning.
    log!(at(day2, ~T[09:30:00]),
      service_id: service_1.id,
      subject_type: "service",
      api_key_id: key_1.id,
      model_id: model_a.id,
      request_type: "embeddings",
      status_code: 200,
      prompt_tokens: 300,
      completion_tokens: 0,
      cost_usd: dec!("3.000000"),
      think: true
    )

    # 4 — service 1 / key 1, chat, local cache hit, paid from a top-up.
    log!(at(day2, ~T[09:45:00]),
      service_id: service_1.id,
      subject_type: "service",
      api_key_id: key_1.id,
      model_id: model_b.id,
      model_provider_id: model_provider.id,
      provider_id: provider.id,
      request_type: "chat",
      status_code: 200,
      prompt_tokens: 400,
      completion_tokens: 200,
      cache_read_tokens: 50,
      cost_usd: dec!("4.000000"),
      latency_ms: 800,
      cache_hit: true,
      credit_topup_id: Ecto.UUID.generate()
    )

    # 5 — service 2 / revoked key, chat, effort applied (reasoning variant).
    log!(at(day2, ~T[23:30:00]),
      service_id: service_2.id,
      subject_type: "service",
      api_key_id: key_2.id,
      request_type: "chat",
      status_code: 200,
      prompt_tokens: 500,
      completion_tokens: 250,
      cost_usd: dec!("5.000000"),
      latency_ms: 1200,
      effort_applied: "high"
    )

    # 6 — the classifier's own billed call: NOT served traffic.
    log!(at(day2, ~T[09:31:00]),
      group_member_id: member_a.id,
      user_id: user_a.id,
      subject_type: "user",
      model_id: model_a.id,
      request_type: "router_decision",
      status_code: 200,
      prompt_tokens: 10,
      completion_tokens: 5,
      cost_usd: dec!("0.250000")
    )

    %{
      member_a: member_a,
      member_b: member_b,
      user_a: user_a,
      user_b: user_b,
      service_1: service_1,
      service_2: service_2,
      key_1: key_1,
      key_2: key_2,
      model_a: model_a,
      model_b: model_b,
      provider_id: provider.id,
      day1: day1,
      day2: day2,
      from: at(day1, ~T[00:00:00]),
      to: at(Date.add(day2, 1), ~T[00:00:00])
    }
  end

  # ---------------------------------------------------------------------
  # HourlyAggregate: router_decision rows are not served traffic
  # ---------------------------------------------------------------------

  describe "HourlyAggregate.aggregate_hours/2" do
    test "excludes router_decision rows from the rollup" do
      {member, user, _} = member_fixture()
      hour = hours_ago(6) |> DateTime.truncate(:second) |> Map.replace!(:minute, 5)

      log!(hour,
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd: dec!("1.000000"),
        latency_ms: 500
      )

      log!(DateTime.add(hour, 10, :second),
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        request_type: "router_decision",
        status_code: 200,
        prompt_tokens: 10,
        completion_tokens: 5,
        cost_usd: dec!("0.750000")
      )

      from = DateTime.add(hour, -3600, :second)
      to = DateTime.add(hour, 3600, :second)

      {:ok, _} = HourlyAggregate.aggregate_hours(from, to)

      summary = Rollup.summary_from_rollup(from: from, to: to)

      assert summary.request_count == 1
      assert_decimal!("1.000000", summary.total_cost_usd)
      assert summary.total_prompt_tokens == 100
      assert summary.total_completion_tokens == 50
      assert summary.error_count == 0

      # Re-aggregating is idempotent: the decision row never resurfaces (the
      # delete+insert pair rebuilds the hour from the served rows only).
      log!(DateTime.add(hour, 20, :second),
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        request_type: "router_decision",
        status_code: 200,
        cost_usd: dec!("0.500000")
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(from, to)

      assert Rollup.summary_from_rollup(from: from, to: to).request_count == 1
    end
  end

  # ---------------------------------------------------------------------
  # Rollup.breakdown_by_user/1: subject_type == "user"
  # ---------------------------------------------------------------------

  describe "Rollup.breakdown_by_user/1" do
    test "ignores service rows that happen to carry a user_id" do
      {member, user, _} = member_fixture()
      service = service_fixture("Mixed Attr Service")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      log!(now,
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        status_code: 200,
        cost_usd: dec!("1.000000")
      )

      # A service row with `user_id` populated (attribution/top-up paths do
      # populate it). It belongs to `breakdown_by_service/1`.
      log!(now,
        service_id: service.id,
        user_id: user.id,
        subject_type: "service",
        status_code: 200,
        cost_usd: dec!("9.000000")
      )

      rows = Rollup.breakdown_by_user(from: hours_ago(1))

      assert [row] = rows
      assert row.user_id == user.id
      assert row.request_count == 1
      assert_decimal!("1.000000", row.cost_usd)
    end
  end

  # ---------------------------------------------------------------------
  # Logs.cost_summary_for_members/2: real avg_tps / avg_latency_ms
  # ---------------------------------------------------------------------

  describe "Logs.cost_summary_for_members/2" do
    test "computes avg_tps and avg_latency_ms from the totals" do
      {member, _user, _} = member_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      log!(now,
        group_member_id: member.id,
        status_code: 200,
        completion_tokens: 50,
        cost_usd: dec!("1.000000"),
        latency_ms: 500
      )

      summary = Logs.cost_summary_for_members([member.id], %{from: hours_ago(1)})

      assert summary.request_count == 1
      assert summary.total_latency_ms == 500
      assert summary.latency_count == 1
      # 50 tokens / 0.5s = 100 t/s (was hardcoded 0.0 before the fix).
      assert summary.avg_tps == 100.0
      assert summary.avg_latency_ms == 500.0
    end

    test "empty member list keeps a nil tps and a zero sample count" do
      summary = Logs.cost_summary_for_members([], %{from: hours_ago(1)})

      assert summary.request_count == 0
      assert summary.latency_count == 0
      assert summary.avg_tps == nil
      assert summary.avg_latency_ms == nil
    end
  end

  # ---------------------------------------------------------------------
  # Logs.compute_tps/2 is the one formula Rollup and StatsQueries share
  # ---------------------------------------------------------------------

  describe "Logs.compute_tps/2" do
    test "nil latency is unmeasured, zero tokens is a measured zero" do
      assert Logs.compute_tps(50, 0) == nil
      assert Logs.compute_tps(0, 500) == 0.0
      assert Logs.compute_tps(50, 500) == 100.0
      assert Logs.compute_tps(nil, 500) == nil
    end
  end

  # ---------------------------------------------------------------------
  # Hybrid merges: summary (error_count + weighted latency) and flat rows
  # ---------------------------------------------------------------------

  describe "StatsQueries hybrid merges" do
    test "summary keeps error_count and weights avg_latency_ms by samples" do
      enable_hybrid!()
      {member, _user, _} = member_fixture()

      # Rollup half: 48h ago, 100 completion tokens in 1000ms, 200.
      log!(hours_ago(48),
        group_member_id: member.id,
        status_code: 200,
        completion_tokens: 100,
        cost_usd: dec!("1.000000"),
        latency_ms: 1000
      )

      # Fresh tail: 1h ago, 50 completion tokens in 500ms, 500 (an error).
      log!(hours_ago(1),
        group_member_id: member.id,
        status_code: 500,
        completion_tokens: 50,
        cost_usd: dec!("2.000000"),
        latency_ms: 500
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == 2
      # The old merge dropped this key entirely.
      assert hybrid.error_count == 1
      assert hybrid.error_count == raw.error_count
      assert hybrid.total_latency_ms == 1500
      assert hybrid.latency_count == 2
      # (1000 + 500) / 2 samples — not the mean of the two halves' means.
      assert hybrid.avg_latency_ms == 750.0
      assert hybrid.avg_latency_ms == raw.avg_latency_ms
      # 150 completion tokens over 1.5s of measured latency.
      assert hybrid.avg_tps == 100.0
    end

    test "usage_by_model_provider_stacked merges the two halves O(n) without duplicates" do
      enable_hybrid!()
      {member, _user, _} = member_fixture()
      model = model_fixture("stacked-model")
      provider = provider_fixture("Stacked Provider")
      model_provider = model_provider_fixture(model, provider)

      # Same (model, provider) pair on BOTH sides: the merge must collapse it.
      for {at, cost} <- [{hours_ago(48), "1.000000"}, {hours_ago(1), "2.000000"}] do
        log!(at,
          group_member_id: member.id,
          model_id: model.id,
          model_provider_id: model_provider.id,
          provider_id: provider.id,
          status_code: 200,
          cost_usd: dec!(cost)
        )
      end

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      stacked =
        StatsQueries.usage_by_model_provider_stacked(
          from: hours_ago(72),
          to: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      assert [row] = stacked
      assert row.model_id == model.id
      assert row.total_requests == 2
      assert_decimal!("3.000000", row.total_cost_usd)
      # ONE provider entry, not one per half.
      assert [provider_row] = row.providers
      assert provider_row.requests == 2
      assert_decimal!("3.000000", provider_row.cost_usd)
    end

    test "busiest_hours breaks ties by the earlier bucket, deterministically" do
      enable_hybrid!()
      {member, _user, _} = member_fixture()

      earlier = hours_ago(49)
      later = hours_ago(48)

      for at <- [earlier, later] do
        log!(at,
          group_member_id: member.id,
          status_code: 200,
          cost_usd: dec!("1.000000")
        )
      end

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      opts = [
        from: hours_ago(72),
        to: DateTime.utc_now() |> DateTime.truncate(:second),
        timezone: "Etc/UTC",
        metric: :cost,
        limit: 5
      ]

      results =
        for _ <- 1..3 do
          StatsQueries.busiest_hours(nil, opts) |> Enum.map(& &1.bucket)
        end

      assert [[first, second] | rest] = results
      assert Enum.all?(rest, &(&1 == [first, second]))
      assert DateTime.compare(first, second) == :lt
    end
  end

  # ---------------------------------------------------------------------
  # FinOps: overview
  # ---------------------------------------------------------------------

  describe "Rollup.finops_overview/1" do
    test "splits served traffic into overall/users/services and never counts the decision row" do
      %{from: from, to: to} = seed_finops!()

      overview = Rollup.finops_overview(from: from, to: to)

      overall = overview.overall
      users = overview.users
      services = overview.services

      # 5 served rows; the router_decision row is not one of them.
      assert overall.requests == 5
      assert_decimal!("15.000000", overall.cost_usd)
      assert overall.prompt_tokens == 1500
      assert overall.completion_tokens == 600
      assert overall.cache_read_tokens == 60
      assert overall.cache_creation_tokens == 5
      assert overall.error_requests == 1
      assert_decimal!("2.000000", overall.error_cost_usd)
      assert overall.fallback_recovered_count == 1
      assert overall.think_requests == 2
      assert_decimal!("8.000000", overall.think_cost_usd)
      assert overall.think_completion_tokens == 250
      assert overall.local_cache_hits == 1
      assert overall.prompt_tokens_saved_est == 7
      assert overall.topup_requests == 1
      assert_decimal!("4.000000", overall.topup_cost_usd)
      # Charged mode: the decision row is the debit, the served column is nil —
      # the amount is reported ONCE (0.25, never 0.5 or 0.25 + 0.75).
      assert_decimal!("0.250000", overall.router_decision_cost_usd)

      assert users.requests == 2
      assert_decimal!("3.000000", users.cost_usd)
      assert users.error_requests == 1
      assert_decimal!("2.000000", users.error_cost_usd)
      assert users.active_subjects == 2

      assert services.requests == 3
      assert_decimal!("12.000000", services.cost_usd)
      assert services.error_requests == 0
      assert services.think_requests == 2
      assert_decimal!("8.000000", services.think_cost_usd)
      assert services.topup_requests == 1
      assert services.active_subjects == 2

      # The parts add up to the whole (Postgres computes all three).
      assert users.requests + services.requests == overall.requests
      assert Decimal.add(users.cost_usd, services.cost_usd) == overall.cost_usd

      refute Map.has_key?(overall, :active_subjects)
    end

    test "reports the absorbed decision cost from the served column when no decision row exists" do
      {member, user, _} = member_fixture()

      day = Date.add(Date.utc_today(), -1)

      log!(at(day, ~T[03:00:00]),
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        status_code: 200,
        cost_usd: dec!("1.000000"),
        router_decision_cost_usd: dec!("0.400000")
      )

      overview =
        Rollup.finops_overview(from: at(day, ~T[00:00:00]), to: at(day, ~T[06:00:00]))

      assert overview.overall.requests == 1
      assert_decimal!("1.000000", overview.overall.cost_usd)
      # Absorbed mode: only the column has it, and it is NOT added to cost_usd.
      assert_decimal!("0.400000", overview.overall.router_decision_cost_usd)
    end

    test "an empty window answers zeroes instead of nil" do
      from = hours_ago(10)
      to = hours_ago(9)

      overview = Rollup.finops_overview(from: from, to: to)

      assert overview.overall.requests == 0
      assert_decimal!("0", overview.overall.cost_usd)
      assert overview.users.active_subjects == 0
      assert overview.services.active_subjects == 0
    end

    test "requires a window (retention contract)" do
      assert_raise ArgumentError, fn -> Rollup.finops_overview([]) end
    end
  end

  # ---------------------------------------------------------------------
  # FinOps: series
  # ---------------------------------------------------------------------

  describe "Rollup.finops_subject_series/1" do
    test "daily series per subject kind, decision rows excluded" do
      %{from: from, to: to, day1: day1, day2: day2} = seed_finops!()

      series = Rollup.finops_subject_series(from: from, to: to, granularity: :day)

      assert [
               %{date: ^day1, subject_type: "user"} = user_day,
               %{date: ^day2, subject_type: "service"} = service_day
             ] = series

      assert user_day.request_count == 2
      assert_decimal!("3.000000", user_day.cost_usd)
      assert_decimal!("2.000000", user_day.error_cost_usd)
      assert_decimal!("0", user_day.think_cost_usd)

      assert service_day.request_count == 3
      assert_decimal!("12.000000", service_day.cost_usd)
      assert_decimal!("0", service_day.error_cost_usd)
      assert_decimal!("8.000000", service_day.think_cost_usd)
    end

    test "hourly series buckets in the requested timezone" do
      {member, user, _} = member_fixture()
      day = Date.add(Date.utc_today(), -1)

      # 02:00 UTC. In a :30-offset zone the LOCAL hour starts at :30 past the
      # UTC hour, so the bucket instant itself moves (this is what makes the
      # timezone option observable at hour granularity).
      log!(at(day, ~T[02:00:00]),
        group_member_id: member.id,
        user_id: user.id,
        subject_type: "user",
        status_code: 200,
        cost_usd: dec!("1.000000")
      )

      opts = [
        from: at(Date.add(day, -1), ~T[00:00:00]),
        to: at(Date.add(day, 1), ~T[00:00:00]),
        granularity: :hour
      ]

      [utc_row] = Rollup.finops_subject_series(opts)
      assert same_instant?(utc_row.date, at(day, ~T[02:00:00]))
      assert utc_row.request_count == 1

      # Asia/Kolkata is +05:30: local 07:30 buckets to 07:00 local = 01:30 UTC.
      [local_row] = Rollup.finops_subject_series(Keyword.put(opts, :timezone, "Asia/Kolkata"))

      assert same_instant?(local_row.date, at(day, ~T[01:30:00]))
      assert local_row.request_count == 1
    end
  end

  # ---------------------------------------------------------------------
  # FinOps: request_type breakdown
  # ---------------------------------------------------------------------

  describe "Rollup.finops_request_type_breakdown/1" do
    test "groups by request_type excluding router_decision, ordered by cost desc" do
      %{from: from, to: to} = seed_finops!()

      rows = Rollup.finops_request_type_breakdown(from: from, to: to)

      assert [%{request_type: "chat"} = chat, %{request_type: "embeddings"} = embeddings] = rows

      assert chat.request_count == 4
      assert chat.user_requests == 2
      assert chat.service_requests == 2
      assert_decimal!("12.000000", chat.cost_usd)
      assert_decimal!("3.000000", chat.user_cost_usd)
      assert_decimal!("9.000000", chat.service_cost_usd)
      assert chat.prompt_tokens == 1200
      assert chat.completion_tokens == 600
      assert chat.cache_read_tokens == 60
      assert chat.error_count == 1
      assert_decimal!("2.000000", chat.error_cost_usd)

      assert embeddings.request_count == 1
      assert embeddings.user_requests == 0
      assert embeddings.service_requests == 1
      assert_decimal!("3.000000", embeddings.cost_usd)
      assert_decimal!("3.000000", embeddings.service_cost_usd)
      assert embeddings.prompt_tokens == 300
      assert embeddings.error_count == 0
    end
  end

  # ---------------------------------------------------------------------
  # FinOps: subject scatter
  # ---------------------------------------------------------------------

  describe "Rollup.finops_subject_scatter/1" do
    test "one row per active subject with its label, ranked by cost" do
      data = seed_finops!()

      rows = Rollup.finops_subject_scatter(from: data.from, to: data.to)

      assert length(rows) == 4

      assert [
               %{subject_type: "service", label: "Finops Service One"} = service_1,
               %{subject_type: "service", label: "Finops Service Two"},
               %{subject_type: "user"} = user_b,
               %{subject_type: "user"} = user_a
             ] = rows

      assert service_1.subject_id == data.service_1.id
      assert service_1.request_count == 2
      assert service_1.billable_requests == 2
      assert service_1.local_cache_hits == 1
      assert_decimal!("7.000000", service_1.cost_usd)
      assert service_1.prompt_tokens == 700
      assert service_1.completion_tokens == 200
      assert service_1.cache_read_tokens == 50
      assert service_1.error_count == 0
      assert_decimal!("3.000000", service_1.think_cost_usd)
      assert_decimal!("4.000000", service_1.topup_cost_usd)

      assert user_b.label == data.user_b.email
      assert user_b.request_count == 1
      assert user_b.billable_requests == 1
      assert user_b.local_cache_hits == 0
      assert_decimal!("2.000000", user_b.cost_usd)
      assert user_b.error_count == 1
      assert_decimal!("2.000000", user_b.error_cost_usd)

      assert user_a.subject_id == data.user_a.id
      assert user_a.request_count == 1
      assert_decimal!("1.000000", user_a.cost_usd)
    end
  end

  describe "Rollup.finops_entity_scatter/2" do
    test "models and providers keep billable requests and thinking tax, router_decision excluded" do
      data = seed_finops!()

      models = Rollup.finops_entity_scatter(:model, from: data.from, to: data.to)
      model_a = Enum.find(models, &(&1.entity_id == data.model_a.id))

      assert model_a.kind == "model"
      assert model_a.label == "finops-model-a"
      assert model_a.requests == 2
      assert model_a.billable_requests == 2
      assert_decimal!("4.000000", model_a.cost_usd)
      assert_decimal!("3.000000", model_a.think_cost_usd)

      # router_decision (log 6, $0.25 sobre model_a) nunca entra a las entidades:
      # el total es el de las filas servidas ($4 + $4 + el bucket sin modelo $7).
      total = models |> Enum.map(& &1.cost_usd) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      assert_decimal!("15.000000", total)
      refute Enum.any?(models, &Decimal.equal?(&1.cost_usd, Decimal.new("0.25")))

      providers = Rollup.finops_entity_scatter(:provider, from: data.from, to: data.to)
      provider = Enum.find(providers, &(&1.label == "Finops Provider"))

      assert provider.kind == "provider"
      assert provider.requests == 2
      assert_decimal!("5.000000", provider.cost_usd)
    end
  end

  describe "FinOps filters (user / provider / service)" do
    test "user_id, provider_id and service_id scope every FinOps read" do
      data = seed_finops!()
      scope = [from: data.from, to: data.to]

      # user_a solo tiene 1 request con costo (el resto del tráfico es de
      # servicios sin usuario): el filtro no debe arrastrar filas ajenas.
      user_view = Rollup.finops_overview(scope ++ [user_id: data.user_a.id])
      assert_decimal!("1.000000", user_view.overall.cost_usd)
      assert user_view.overall.requests == 1

      provider_view = Rollup.finops_overview(scope ++ [provider_id: data.provider_id])
      assert_decimal!("5.000000", provider_view.overall.cost_usd)
      assert provider_view.overall.requests == 2

      service_view = Rollup.finops_overview(scope ++ [service_id: data.service_1.id])
      assert_decimal!("7.000000", service_view.overall.cost_usd)

      models = Rollup.finops_entity_scatter(:model, scope ++ [user_id: data.user_a.id])
      assert Enum.map(models, & &1.label) == ["finops-model-a"]
      assert_decimal!("1.000000", hd(models).cost_usd)
    end
  end

  describe "FinOps: buckets y overhead (fixes verificados)" do
    test "el overhead del router suma decisión + atribución y cuadra con sus partes" do
      data = seed_finops!()

      # Una servida con atribución del clasificador, en la MISMA ventana que la
      # fila de decisión: el CASE por ventana tiraba esta atribución.
      log!(at(data.day2, ~T[10:00:00]),
        subject_type: "user",
        user_id: data.user_a.id,
        group_member_id: data.member_a.id,
        request_type: "chat",
        status_code: 200,
        prompt_tokens: 10,
        completion_tokens: 5,
        cost_usd: dec!("0.100000"),
        router_decision_cost_usd: dec!("0.050000")
      )

      overview = Rollup.finops_overview(from: data.from, to: data.to)

      # decisión $0.25 (log 6) + atribución $0.05 de la servida.
      assert_decimal!("0.300000", overview.overall.router_decision_cost_usd)

      parts =
        Decimal.add(
          overview.users.router_decision_cost_usd,
          overview.services.router_decision_cost_usd
        )

      assert Decimal.equal?(overview.overall.router_decision_cost_usd, parts)
    end

    test "errors y thinking son excluyentes: el razonamiento de un fallo no se resta dos veces" do
      data = seed_finops!()

      # Fallo CON razonamiento: $2 que son error y thinking al mismo tiempo.
      log!(at(data.day2, ~T[11:00:00]),
        subject_type: "service",
        service_id: data.service_1.id,
        request_type: "chat",
        status_code: 500,
        prompt_tokens: 100,
        completion_tokens: 100,
        cost_usd: dec!("2.000000"),
        think: true
      )

      overview = Rollup.finops_overview(from: data.from, to: data.to)

      # `think_cost_usd` sí lo incluye; `think_cost_ok_usd` no (es de las que
      # respondieron), y esa es la llave que resta la anatomía.
      assert_decimal!(
        "2.000000",
        Decimal.sub(overview.overall.think_cost_usd, overview.overall.think_cost_ok_usd)
      )

      # Invariante de la anatomía: errores + thinking_ok nunca pasa del costo,
      # así el gasto útil jamás se vuelve negativo ni el total se infla.
      for block <- [overview.overall, overview.users, overview.services] do
        covered = Decimal.add(block.error_cost_usd, block.think_cost_ok_usd)
        assert Decimal.compare(covered, block.cost_usd) in [:lt, :eq]
      end
    end

    test "el tráfico servido excluye al clasificador con y sin rollup" do
      data = seed_finops!()
      window = [from: data.from, to: data.to]

      # Servidas facturables: logs 1..5 (el 6 es el clasificador).
      served = 5

      HourlyAggregate.aggregate_hours(data.from, data.to)
      with_rollup = StatsQueries.summary(window)

      # Sin rollup: el guard no puede cubrir la ventana y cae al camino crudo.
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM request_metrics_hourly", [])
      without_rollup = StatsQueries.summary(window)

      assert with_rollup.request_count == served
      assert without_rollup.request_count == served
    end
  end

  # ---------------------------------------------------------------------
  # FinOps: per service
  # ---------------------------------------------------------------------

  describe "Rollup.service_finops_summary/2" do
    test "scopes the overview, the request-type split, keys and models to one service" do
      data = seed_finops!()

      summary =
        Rollup.service_finops_summary(data.service_1.id, from: data.from, to: data.to)

      assert summary.overview.requests == 2
      assert_decimal!("7.000000", summary.overview.cost_usd)
      assert summary.overview.local_cache_hits == 1
      assert summary.overview.think_requests == 1
      assert summary.overview.topup_requests == 1

      assert [%{request_type: "chat"} = chat, %{request_type: "embeddings"}] =
               summary.by_request_type

      assert chat.request_count == 1
      assert_decimal!("4.000000", chat.cost_usd)
      assert chat.service_requests == 1
      assert chat.user_requests == 0

      assert [%{label: "svc-one-primary", status: "active"} = key_row] = summary.by_key
      assert key_row.api_key_id == data.key_1.id
      assert key_row.request_count == 2
      assert_decimal!("7.000000", key_row.cost_usd)
      assert_decimal!("3.000000", key_row.think_cost_usd)
      assert key_row.error_count == 0

      assert [%{model_name: "finops-model-b"} = expensive, %{model_name: "finops-model-a"}] =
               summary.by_model

      assert expensive.request_count == 1
      assert_decimal!("4.000000", expensive.cost_usd)
    end

    test "honours the :api_key_id scope ('all' and a uuid)" do
      data = seed_finops!()

      all =
        Rollup.service_finops_summary(data.service_1.id,
          from: data.from,
          to: data.to,
          api_key_id: "all"
        )

      assert all.overview.requests == 2

      other =
        Rollup.service_finops_summary(data.service_1.id,
          from: data.from,
          to: data.to,
          api_key_id: data.key_2.id
        )

      assert other.overview.requests == 0
      assert other.by_key == []
      assert other.by_model == []
    end

    test "nil service id answers the empty shape" do
      summary = Rollup.service_finops_summary(nil, from: hours_ago(2))

      assert summary.overview.requests == 0
      assert summary.by_request_type == []
      assert summary.by_key == []
      assert summary.by_model == []
    end
  end

  describe "Rollup.service_finops_series/2" do
    test "daily and hourly series for one service, with the api-key scope" do
      data = seed_finops!()

      [daily] =
        Rollup.service_finops_series(data.service_1.id,
          from: data.from,
          to: data.to,
          granularity: :day
        )

      assert daily.date == data.day2
      assert daily.request_count == 2
      assert_decimal!("7.000000", daily.cost_usd)
      assert_decimal!("0", daily.error_cost_usd)
      assert_decimal!("3.000000", daily.think_cost_usd)

      hourly =
        Rollup.service_finops_series(data.service_1.id,
          from: data.from,
          to: data.to,
          granularity: :hour
        )

      assert [%{request_count: 2} = only_hour] = hourly
      assert same_instant?(only_hour.date, at(data.day2, ~T[09:00:00]))
      assert_decimal!("7.000000", only_hour.cost_usd)

      assert Rollup.service_finops_series(data.service_1.id,
               from: data.from,
               to: data.to,
               api_key_id: data.key_2.id
             ) == []

      assert Rollup.service_finops_series(nil, from: data.from) == []
    end
  end
end
