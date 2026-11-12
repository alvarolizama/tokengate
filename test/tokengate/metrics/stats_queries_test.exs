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
  alias Tokengate.Providers

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

  defp service_fixture do
    {:ok, service} =
      Accounts.create_service(%{name: "SQ Service #{System.unique_integer([:positive])}"})

    service
  end

  defp model_fixture do
    {:ok, model} =
      Providers.create_model(%{
        "name" => "sq-#{System.unique_integer([:positive])}",
        "context_window" => 128_000
      })

    model
  end

  defp rollup_provider_fixture(name) do
    {:ok, provider} =
      Providers.create_provider(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        base_url: "http://localhost:#{System.unique_integer([:positive])}"
      })

    provider
  end

  defp log_service_request(service_id, inserted_at, overrides) do
    attrs =
      @base_attrs
      |> Map.merge(Map.new(overrides))
      |> Map.put(:service_id, service_id)
      |> Map.put(:group_member_id, nil)
      |> Map.put(:subject_type, "service")
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _} = Logs.log_request(attrs)
    :ok
  end

  defp hours_ago(h),
    do: DateTime.add(DateTime.utc_now(), -h * 3600, :second) |> DateTime.truncate(:second)

  defp floor_to_hour(%DateTime{} = dt),
    do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}

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
      gpt = model_fixture()
      claude = model_fixture()

      log_request(member.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member.id, hours_ago(1), model_id: gpt.id, model_requested: gpt.name)
      log_request(member.id, hours_ago(1), model_id: claude.id, model_requested: claude.name)

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

    test "summary honours a service filter (the rollup has no service dimension)" do
      {member, _group} = group_member_fixture()
      service = service_fixture()

      # One user request and one service request, both in the rollup window.
      # The rollup buckets by group_member_id (services have a null one), so a
      # service-filtered summary must NOT pick up the user's row.
      log_request(member.id, hours_ago(48), cost_usd: Decimal.new("5.000000"))
      log_service_request(service.id, hours_ago(48), cost_usd: Decimal.new("1.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.summary(%{service_id: service.id, from: from, to: to})
      raw = Logs.cost_summary(%{service_id: service.id, from: from, to: to})

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
    end

    test "summary over a recent-only window does not pull in pre-window rows" do
      {member, _group} = group_member_fixture()

      # One log 2h ago — inside the rollup tail band, but OUTSIDE a 1h window.
      log_request(member.id, hours_ago(2), cost_usd: Decimal.new("9.000000"))

      from = hours_ago(1)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == raw.request_count
    end

    test "summary over a window that ENDS before the tail cutoff ignores newer rows" do
      {member, _group} = group_member_fixture()

      # The window of interest: 30h–27h ago (fully inside the rollup band).
      log_request(member.id, hours_ago(30), cost_usd: Decimal.new("1.000000"))
      log_request(member.id, hours_ago(28), cost_usd: Decimal.new("2.000000"))
      # Newer rows that start after the window ends — the previous-period KPI
      # must NOT fold these in just because the rollup holds them.
      log_request(member.id, hours_ago(10), cost_usd: Decimal.new("50.000000"))
      log_request(member.id, hours_ago(1), cost_usd: Decimal.new("50.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(31), hours_ago(3))

      from = hours_ago(31)
      to = hours_ago(27)

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
      assert Decimal.compare(hybrid.total_cost_usd, Decimal.new("3.000000")) == :eq
    end

    test "summary over a window ENDING on an exact hour edge does not swallow the next bucket" do
      {member, _group} = group_member_fixture()

      # Anchor the window BEFORE inserting: `hours_ago/1` is evaluated per
      # call, so computing `from` afterwards can land one second past the
      # row at the same offset and drop it from both halves (flaky assert).
      from = hours_ago(48) |> DateTime.add(-60, :second)

      # Inside the window (48h ago, whole hours). The window ends at an
      # EXACT hour boundary: the bucket that STARTS at `to` belongs to the
      # next period and must stay out (this is the previous-period shape
      # behind every KPI delta).
      log_request(member.id, hours_ago(48), cost_usd: Decimal.new("1.000000"))
      log_request(member.id, hours_ago(47), cost_usd: Decimal.new("2.000000"))

      to = hours_ago(30) |> floor_to_hour()

      # Right AT the window end — inside (`inserted_at <= to` on the raw side).
      log_request(member.id, to, cost_usd: Decimal.new("4.000000"))

      # 60s AFTER the edge: lives in the bucket STARTING at `to` — outside
      # the window, and exactly what `hour_utc <= to` used to swallow whole.
      log_request(member.id, DateTime.add(to, 60, :second), cost_usd: Decimal.new("8.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
      # 1 + 2 + 4 = 7; the 8.00 row after the edge must NOT be folded in.
      assert Decimal.compare(hybrid.total_cost_usd, Decimal.new("7.000000")) == :eq
    end

    test "summary over a window STARTING mid-hour keeps its partial first bucket" do
      {member, _group} = group_member_fixture()

      # from = 47h30m ago (mid-hour): the first bucket [from, ceil_hour(from))
      # is PARTIAL and must be answered raw, not dropped. Both rows are 47h
      # ago — one before the hour edge, one just after it.
      from = hours_ago(47) |> DateTime.add(-1800, :second)
      after_edge = hours_ago(47) |> DateTime.add(60, :second)

      log_request(member.id, from, cost_usd: Decimal.new("1.000000"))
      log_request(member.id, after_edge, cost_usd: Decimal.new("2.000000"))
      log_request(member.id, hours_ago(46), cost_usd: Decimal.new("4.000000"))
      # Pre-window row: 30 minutes before `from` — must stay out.
      log_request(member.id, DateTime.add(from, -60, :second), cost_usd: Decimal.new("16.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
      # 1 + 2 + 4 = 7; the 16.00 pre-window row must NOT be folded in.
      assert Decimal.compare(hybrid.total_cost_usd, Decimal.new("7.000000")) == :eq
    end

    test "merged avg_tps counts the raw tail latency" do
      {member, _group} = group_member_fixture()

      # Rollup part: 48h ago — 50 tokens in 500ms (100 tps).
      log_request(member.id, hours_ago(48),
        cost_usd: Decimal.new("1.000000"),
        prompt_tokens: 100,
        completion_tokens: 50,
        latency_ms: 500
      )

      # Fresh tail: 1h ago — 50 tokens in 1500ms (33.3 tps).
      log_request(member.id, hours_ago(1),
        cost_usd: Decimal.new("1.000000"),
        prompt_tokens: 100,
        completion_tokens: 50,
        latency_ms: 1500
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.summary(%{from: from, to: to})
      raw = Logs.cost_summary(%{from: from, to: to})

      # 100 tokens / 2.0s = 50 tps overall; losing the tail's latency would
      # read 100 tokens / 0.5s = 200 tps.
      assert hybrid.avg_tps == raw.avg_tps
      assert hybrid.avg_tps == 50.0
    end

    test "summary honours a provider filter on BOTH halves" do
      {member, _group} = group_member_fixture()
      openai = rollup_provider_fixture("OpenAI")
      azure = rollup_provider_fixture("Azure")

      # Rollup half: one log per provider, 48h ago.
      log_request(member.id, hours_ago(48),
        provider_id: openai.id,
        cost_usd: Decimal.new("5.000000")
      )

      log_request(member.id, hours_ago(48),
        provider_id: azure.id,
        cost_usd: Decimal.new("9.000000")
      )

      # Fresh tail: one log per provider, 1h ago.
      log_request(member.id, hours_ago(1),
        provider_id: openai.id,
        cost_usd: Decimal.new("1.000000")
      )

      log_request(member.id, hours_ago(1),
        provider_id: azure.id,
        cost_usd: Decimal.new("2.000000")
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      filters = %{provider_id: openai.id, from: from, to: to}

      hybrid = StatsQueries.summary(filters)
      raw = Logs.cost_summary(filters)

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
      # 5 + 1 = 6 — the Azure rows stay out on both halves.
      assert Decimal.compare(hybrid.total_cost_usd, Decimal.new("6.000000")) == :eq
    end

    test "summary honours a model filter on BOTH halves" do
      {member, _group} = group_member_fixture()
      gpt = model_fixture()
      claude = model_fixture()

      log_request(member.id, hours_ago(48),
        model_id: gpt.id,
        model_requested: gpt.name,
        cost_usd: Decimal.new("3.000000")
      )

      log_request(member.id, hours_ago(48),
        model_id: claude.id,
        model_requested: claude.name,
        cost_usd: Decimal.new("7.000000")
      )

      log_request(member.id, hours_ago(1),
        model_id: gpt.id,
        model_requested: gpt.name,
        cost_usd: Decimal.new("2.000000")
      )

      log_request(member.id, hours_ago(1),
        model_id: claude.id,
        model_requested: claude.name,
        cost_usd: Decimal.new("8.000000")
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      filters = %{model_id: gpt.id, from: from, to: to}

      hybrid = StatsQueries.summary(filters)
      raw = Logs.cost_summary(filters)

      assert hybrid.request_count == raw.request_count
      assert Decimal.compare(hybrid.total_cost_usd, raw.total_cost_usd) == :eq
      assert Decimal.compare(hybrid.total_cost_usd, Decimal.new("5.000000")) == :eq
    end

    # P2-11 regression: members of the SAME group share group_id, so the old
    # "any key matches" identity merged their rows into one. Identity is the
    # FULL dimension tuple, so each member keeps its own row.
    test "breakdown_by_member keeps members of the same group apart" do
      {member_a, group} = group_member_fixture()

      {:ok, user_b} =
        Accounts.register_user(%{
          email: "sq-b-#{System.unique_integer([:positive])}@example.com",
          name: "SQ User B",
          password: "ValidPassword123"
        })

      {:ok, member_b} = Accounts.create_group_member(%{group_id: group.id, user_id: user_b.id})

      log_request(member_a.id, hours_ago(48), cost_usd: Decimal.new("1.000000"))
      log_request(member_b.id, hours_ago(48), cost_usd: Decimal.new("2.000000"))
      log_request(member_a.id, hours_ago(1), cost_usd: Decimal.new("0.500000"))
      log_request(member_b.id, hours_ago(1), cost_usd: Decimal.new("0.500000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      hybrid = StatsQueries.breakdown_by_member(nil, from: from, to: to)
      raw = Tokengate.Metrics.Rollup.breakdown_by_member(nil, from: from, to: to)

      assert length(hybrid) == 2
      assert length(raw) == 2

      by_member = fn rows -> Map.new(rows, &{&1.group_member_id, &1}) end
      h = by_member.(hybrid)
      r = by_member.(raw)

      assert Map.keys(h) |> Enum.sort() == Map.keys(r) |> Enum.sort()

      for id <- Map.keys(h) do
        assert h[id].request_count == r[id].request_count
        assert Decimal.compare(h[id].cost_usd, r[id].cost_usd) == :eq
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

  # ---------------------------------------------------------------------
  # Hybrid parity — overview heavy cards (hour×provider, model×provider
  # stacked, busiest hours): the rollup side + raw tail must match the
  # pure-raw aggregation over the same window.
  # ---------------------------------------------------------------------
  describe "overview heavy cards hybrid parity" do
    setup do
      original = Application.get_env(:tokengate, :stats_rollup)
      Application.put_env(:tokengate, :stats_rollup, hybrid: true)
      on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, original) end)
      :ok
    end

    defp provider_fixture(name) do
      {:ok, provider} =
        Providers.create_provider(%{
          name: name,
          base_url: "http://localhost:#{System.unique_integer([:positive])}"
        })

      provider
    end

    defp model_provider_fixture(model, provider) do
      unique = System.unique_integer([:positive])

      {:ok, credential} =
        Providers.create_credential(%{
          provider_id: provider.id,
          name: "key-#{unique}",
          api_key_encrypted: "sk-test-#{unique}",
          status: "active"
        })

      {:ok, model_provider} =
        Providers.create_model_provider(%{
          model_id: model.id,
          credential_id: credential.id,
          provider_model: "gpt-4o-#{unique}",
          enabled: true
        })

      model_provider
    end

    test "usage_by_hour_of_day_by_provider matches the raw profile" do
      {member, _group} = group_member_fixture()
      openai = provider_fixture("OpenAI")
      azure = provider_fixture("Azure")

      # Parte vieja (rollup): 3 requests — dos OpenAI, una Azure.
      log_request(member.id, hours_ago(48),
        provider_id: openai.id,
        cost_usd: Decimal.new("1.000000")
      )

      log_request(member.id, hours_ago(48),
        provider_id: openai.id,
        cost_usd: Decimal.new("0.500000")
      )

      log_request(member.id, hours_ago(47),
        provider_id: azure.id,
        cost_usd: Decimal.new("2.000000")
      )

      # Cola cruda: una OpenAI.
      log_request(member.id, hours_ago(1),
        provider_id: openai.id,
        cost_usd: Decimal.new("0.250000")
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to, timezone: "Etc/UTC"]

      hybrid = StatsQueries.usage_by_hour_of_day_by_provider(opts)
      raw = Tokengate.Metrics.Rollup.usage_by_hour_of_day_by_provider(opts)

      assert length(hybrid) == 24 and length(raw) == 24

      # Cada hora: mismos proveedores, mismos requests, mismo costo.
      for {h, r} <- Enum.zip(hybrid, raw) do
        assert h.hour == r.hour
        assert h.total_requests == r.total_requests
        assert Decimal.compare(h.total_cost_usd, r.total_cost_usd) == :eq

        by_name = fn rows -> Map.new(rows, &{&1.provider_name, &1.requests}) end
        assert by_name.(h.providers) == by_name.(r.providers)
      end

      total = Enum.reduce(hybrid, 0, &(&1.total_requests + &2))
      assert total == 4
    end

    test "usage_by_model_provider_stacked matches the raw stacked chart" do
      {member, _group} = group_member_fixture()
      gpt = model_fixture()
      openai = provider_fixture("OpenAI")
      azure = provider_fixture("Azure")
      mp_openai = model_provider_fixture(gpt, openai)
      mp_azure = model_provider_fixture(gpt, azure)

      log_request(member.id, hours_ago(48),
        model_id: gpt.id,
        provider_id: openai.id,
        model_provider_id: mp_openai.id,
        cost_usd: Decimal.new("1.000000")
      )

      log_request(member.id, hours_ago(48),
        model_id: gpt.id,
        provider_id: azure.id,
        model_provider_id: mp_azure.id,
        cost_usd: Decimal.new("2.000000")
      )

      log_request(member.id, hours_ago(1),
        model_id: gpt.id,
        provider_id: openai.id,
        model_provider_id: mp_openai.id,
        cost_usd: Decimal.new("0.250000")
      )

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.usage_by_model_provider_stacked(opts)
      raw = Tokengate.Metrics.Rollup.usage_by_model_provider_stacked(opts)

      assert length(hybrid) == length(raw)
      [h | _] = hybrid
      [r | _] = raw

      assert h.model_name == r.model_name
      assert h.total_requests == r.total_requests

      assert Decimal.compare(
               Enum.reduce(h.providers, Decimal.new(0), &Decimal.add(&1.cost_usd, &2)),
               Enum.reduce(r.providers, Decimal.new(0), &Decimal.add(&1.cost_usd, &2))
             ) == :eq

      by_name = fn providers -> Map.new(providers, &{&1.provider_name, &1.requests}) end
      assert by_name.(h.providers) == by_name.(r.providers)
      assert by_name.(h.providers) == %{"OpenAI" => 2, "Azure" => 1}
    end

    test "busiest_hours matches the raw top buckets" do
      {member, _group} = group_member_fixture()

      log_request(member.id, hours_ago(48))
      log_request(member.id, hours_ago(48))
      log_request(member.id, hours_ago(48))
      log_request(member.id, hours_ago(47))
      log_request(member.id, hours_ago(1))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to, timezone: "Etc/UTC"]

      hybrid = StatsQueries.busiest_hours(nil, opts)
      raw = Tokengate.Metrics.Rollup.busiest_hours(nil, opts)

      # El bucket de la cola (1h ago) no entra al top (1 request vs 3 y 1)…
      # salvo empate con el de 47h — ambos tienen 1. Los dos primeros
      # puestos son estables: 3 requests (48h ago) y luego el empate.
      assert hd(hybrid).request_count == 3
      assert hd(raw).request_count == 3

      counts = fn rows -> Enum.map(rows, & &1.request_count) end
      assert counts.(hybrid) == counts.(raw)

      total = Enum.reduce(hybrid, 0, &(&1.request_count + &2))
      assert total == Enum.reduce(raw, 0, &(&1.request_count + &2))
    end
  end
end
