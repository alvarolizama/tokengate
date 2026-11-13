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

  # ---------------------------------------------------------------------
  # Tab reads: models / groups / users hybrid parity + rollup-coverage guard
  # ---------------------------------------------------------------------
  describe "tab breakdowns hybrid parity" do
    setup do
      original = Application.get_env(:tokengate, :stats_rollup)
      Application.put_env(:tokengate, :stats_rollup, hybrid: true)
      on_exit(fn -> Application.put_env(:tokengate, :stats_rollup, original) end)
      :ok
    end

    defp add_member(group, user_id) do
      {:ok, member} = Accounts.create_group_member(%{group_id: group.id, user_id: user_id})
      member
    end

    defp tail_floor do
      DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> floor_to_hour()
    end

    defp by_id(rows, key) do
      Map.new(rows, &{Map.fetch!(&1, key), &1})
    end

    defp assert_rows_match(hybrid, raw, key) do
      h = by_id(hybrid, key)
      r = by_id(raw, key)

      assert Map.keys(h) |> Enum.sort() == Map.keys(r) |> Enum.sort()

      for id <- Map.keys(h) do
        assert h[id].request_count == r[id].request_count
        assert Decimal.compare(h[id].cost_usd, r[id].cost_usd) == :eq
        assert h[id].prompt_tokens == r[id].prompt_tokens
        assert h[id].completion_tokens == r[id].completion_tokens
      end
    end

    test "breakdown_by_model parity on the models tab (rollup + tail)" do
      {member, _group} = group_member_fixture()
      gpt = model_fixture()
      claude = model_fixture()

      log_request(member.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member.id, hours_ago(48), model_id: claude.id, model_requested: claude.name)
      log_request(member.id, hours_ago(1), model_id: gpt.id, model_requested: gpt.name)

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.breakdown_by_model(nil, opts)
      raw = Tokengate.Metrics.Rollup.breakdown_by_model(nil, opts)

      assert_rows_match(hybrid, raw, :model_id)
    end

    test "breakdown_by_model honours the member scope on BOTH halves" do
      {member_a, group} = group_member_fixture()

      {:ok, user_b} =
        Accounts.register_user(%{
          email: "sq-scope-#{System.unique_integer([:positive])}@example.com",
          name: "SQ Scope B",
          password: "ValidPassword123"
        })

      member_b = add_member(group, user_b.id)
      gpt = model_fixture()

      log_request(member_a.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member_b.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member_b.id, hours_ago(1), model_id: gpt.id, model_requested: gpt.name)

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to, member_ids: [member_a.id]]

      hybrid = StatsQueries.breakdown_by_model(nil, opts)
      raw = Tokengate.Metrics.Rollup.breakdown_by_model(nil, opts)

      assert_rows_match(hybrid, raw, :model_id)
      # Exactly the one request of member_a in the closed window — the rollup
      # half used to ignore `member_ids` and answer org-wide.
      assert Enum.map(hybrid, & &1.request_count) == [1]
    end

    test "breakdown_by_group parity on the groups tab" do
      {member_a, _group_a} = group_member_fixture()

      {:ok, group_b} =
        Accounts.create_group(%{name: "SQ Group B #{System.unique_integer([:positive])}"})

      {:ok, user_b} =
        Accounts.register_user(%{
          email: "sq-gb-#{System.unique_integer([:positive])}@example.com",
          name: "SQ GB",
          password: "ValidPassword123"
        })

      member_b = add_member(group_b, user_b.id)

      log_request(member_a.id, hours_ago(48), cost_usd: Decimal.new("3.000000"))
      log_request(member_b.id, hours_ago(48), cost_usd: Decimal.new("7.000000"))
      log_request(member_a.id, hours_ago(1), cost_usd: Decimal.new("1.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.breakdown_by_group(opts)
      raw = Tokengate.Metrics.Rollup.breakdown_by_group(opts)

      assert_rows_match(hybrid, raw, :group_id)
      assert length(hybrid) == 2
    end

    test "breakdown_by_user parity, one row per durable user" do
      {member_a, group} = group_member_fixture()

      {:ok, user_b} =
        Accounts.register_user(%{
          email: "sq-u2-#{System.unique_integer([:positive])}@example.com",
          name: "SQ U2",
          password: "ValidPassword123"
        })

      member_b = add_member(group, user_b.id)

      log_request(member_a.id, hours_ago(48), cost_usd: Decimal.new("2.000000"))
      log_request(member_b.id, hours_ago(48), cost_usd: Decimal.new("5.000000"))
      log_request(member_a.id, hours_ago(1), cost_usd: Decimal.new("1.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.breakdown_by_user(opts)
      raw = Tokengate.Metrics.Rollup.breakdown_by_user(opts)

      assert_rows_match(hybrid, raw, :user_id)
      assert length(hybrid) == 2

      # Membership context parity too: memberships/groups come from the union
      # of both halves.
      for h <- hybrid do
        r = Enum.find(raw, &(&1.user_id == h.user_id))
        assert h.memberships == r.memberships
        assert h.user_email == r.user_email
        assert Enum.map(h.groups, & &1.id) == Enum.map(r.groups, & &1.id)
      end
    end

    # Member turnover: the user's old membership is deleted (request_logs and
    # the rollup buckets keep `user_id`, `group_member_id` goes NULL) and a new
    # membership is created for the fresh tail. The user must still answer ONE
    # row carrying the whole window — this is the durable-identity contract.
    test "breakdown_by_user keeps the whole window across a membership turnover" do
      {member_a, group} = group_member_fixture()

      log_request(member_a.id, hours_ago(48), cost_usd: Decimal.new("4.000000"))
      log_request(member_a.id, hours_ago(47), cost_usd: Decimal.new("2.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      {:ok, group_b} =
        Accounts.create_group(%{name: "SQ Turnover #{System.unique_integer([:positive])}"})

      # `group_members` allows ONE membership per user, so the turnover is
      # delete-then-create — after the rollup captured the old buckets.
      {:ok, _} = Accounts.delete_group_member(member_a)
      member_b = add_member(group_b, member_a.user_id)

      log_request(member_b.id, hours_ago(1), cost_usd: Decimal.new("1.500000"))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.breakdown_by_user(opts)
      raw = Tokengate.Metrics.Rollup.breakdown_by_user(opts)

      assert length(hybrid) == 1
      [row] = hybrid

      assert row.user_id == member_b.user_id
      assert row.request_count == 3
      assert Decimal.compare(row.cost_usd, Decimal.new("7.500000")) == :eq
      # Only the LIVE membership counts, on both halves.
      assert row.memberships == 1
      assert Enum.map(row.groups, & &1.id) == [group_b.id]
      refute Enum.any?(row.groups, &(&1.id == group.id))

      assert_rows_match(hybrid, raw, :user_id)
    end

    # The KPI of a scoped viewer must be scoped by the DURABLE user id, not by
    # the current membership list: after a rotation the old membership is gone
    # and `member_ids`-scoped totals lose that history.
    test "summary scoped by user_ids keeps the rotated history" do
      {member_a, _group} = group_member_fixture()

      log_request(member_a.id, hours_ago(48), cost_usd: Decimal.new("2.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      {:ok, group_b} =
        Accounts.create_group(%{name: "SQ SumTurn #{System.unique_integer([:positive])}"})

      {:ok, _} = Accounts.delete_group_member(member_a)
      member_b = add_member(group_b, member_a.user_id)

      log_request(member_b.id, hours_ago(1), cost_usd: Decimal.new("1.000000"))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)

      durable = StatsQueries.summary(%{from: from, to: to, user_ids: [member_b.user_id]})
      current_only = StatsQueries.summary(%{from: from, to: to, group_member_ids: [member_b.id]})

      assert durable.request_count == 2
      assert Decimal.compare(durable.total_cost_usd, Decimal.new("3.000000")) == :eq
      # The membership-scoped read only sees the tail — the shape the KPI had.
      assert current_only.request_count == 1
    end

    test "breakdown_by_user honours a user_ids scope on BOTH halves" do
      {member_a, group} = group_member_fixture()

      {:ok, user_b} =
        Accounts.register_user(%{
          email: "sq-scope-u-#{System.unique_integer([:positive])}@example.com",
          name: "SQ Scope U",
          password: "ValidPassword123"
        })

      member_b = add_member(group, user_b.id)

      log_request(member_a.id, hours_ago(48), cost_usd: Decimal.new("2.000000"))
      log_request(member_b.id, hours_ago(48), cost_usd: Decimal.new("10.000000"))
      log_request(member_a.id, hours_ago(1), cost_usd: Decimal.new("1.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to, user_ids: [member_a.user_id]]

      hybrid = StatsQueries.breakdown_by_user(opts)

      assert [row] = hybrid
      assert row.user_id == member_a.user_id
      assert row.request_count == 2

      raw =
        Tokengate.Metrics.Rollup.breakdown_by_user(opts)
        |> Enum.filter(&(&1.user_id in [member_a.user_id]))

      assert_rows_match(hybrid, raw, :user_id)
    end

    test "dashboard batch (model + member from ONE read) matches the separate reads" do
      {member_a, group} = group_member_fixture()

      {:ok, user_b} =
        Accounts.register_user(%{
          email: "sq-batch-#{System.unique_integer([:positive])}@example.com",
          name: "SQ Batch",
          password: "ValidPassword123"
        })

      member_b = add_member(group, user_b.id)
      gpt = model_fixture()
      claude = model_fixture()
      user_ids = [member_a.user_id, member_b.user_id]

      log_request(member_a.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member_b.id, hours_ago(48), model_id: claude.id, model_requested: claude.name)
      log_request(member_a.id, hours_ago(1), model_id: claude.id, model_requested: claude.name)

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(3))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to, user_ids: user_ids]

      {batch_models, batch_members} = StatsQueries.breakdown_by_model_and_member(opts)
      models = StatsQueries.breakdown_by_model(nil, opts)
      members = StatsQueries.breakdown_by_member(nil, opts)

      assert_rows_match(batch_models, models, :model_id)
      assert_rows_match(batch_members, members, :group_member_id)
      assert length(batch_members) == 2
    end

    test "empty rollup falls back to raw for the tab reads (never tail-only figures)" do
      {member, _group} = group_member_fixture()
      gpt = model_fixture()

      # Closed-window traffic but NO rollup rows at all: the fresh-deploy /
      # no-backfill shape.
      log_request(member.id, hours_ago(48), model_id: gpt.id, model_requested: gpt.name)
      log_request(member.id, hours_ago(47), model_id: gpt.id, model_requested: gpt.name)
      log_request(member.id, hours_ago(1), model_id: gpt.id, model_requested: gpt.name)

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      assert StatsQueries.summary(%{from: from, to: to}).request_count == 3

      assert Decimal.compare(
               StatsQueries.summary(%{from: from, to: to}).total_cost_usd,
               Decimal.new("2.400000")
             ) == :eq

      model_hybrid = StatsQueries.breakdown_by_model(nil, opts)
      assert Enum.map(model_hybrid, & &1.request_count) == [3]

      group_hybrid = StatsQueries.breakdown_by_group(opts)
      assert Enum.map(group_hybrid, & &1.request_count) == [3]

      user_hybrid = StatsQueries.breakdown_by_user(opts)
      assert Enum.map(user_hybrid, & &1.request_count) == [3]
    end

    test "a rollup gap at the newest closed hour falls back to raw" do
      {member, _group} = group_member_fixture()

      bound = tail_floor()
      # Inside the closed window, at the newest closed hour: raw has it, the
      # rollup does NOT (the worker "was down" from 24h ago on).
      log_request(member.id, DateTime.add(bound, -1800, :second),
        cost_usd: Decimal.new("6.000000")
      )

      log_request(member.id, hours_ago(48), cost_usd: Decimal.new("3.000000"))
      # Fresh tail.
      log_request(member.id, hours_ago(1), cost_usd: Decimal.new("1.000000"))

      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(24))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.breakdown_by_model(nil, opts)
      raw = Tokengate.Metrics.Rollup.breakdown_by_model(nil, opts)

      # 3 + 6 + 1 requests: the 6.00 row sits in the gap and must be counted.
      assert Enum.map(hybrid, & &1.request_count) == Enum.map(raw, & &1.request_count)
      assert Enum.sum(Enum.map(hybrid, & &1.request_count)) == 3

      assert Decimal.compare(
               Enum.reduce(hybrid, Decimal.new(0), &Decimal.add(&1.cost_usd, &2)),
               Decimal.new("10.000000")
             ) == :eq

      assert StatsQueries.summary(%{from: from, to: to}).request_count == 3
      assert Enum.map(StatsQueries.breakdown_by_user(opts), & &1.request_count) == [3]
    end

    # Partial rollup: the newest closed hours are there, an INTERIOR hour is
    # missing (a backfill that skipped a day). A presence probe would call this
    # covered and undercount; the exact count reconciliation catches it and the
    # full-window raw answer must not double count the tail either.
    test "an interior rollup gap falls back to raw without double counting" do
      {member, _group} = group_member_fixture()

      log_request(member.id, hours_ago(48), cost_usd: Decimal.new("2.000000"))
      log_request(member.id, hours_ago(30), cost_usd: Decimal.new("4.000000"))
      log_request(member.id, hours_ago(1), cost_usd: Decimal.new("1.000000"))

      # Rollup covers 72h→36h only: 48h IS aggregated, 30h is the hole.
      {:ok, _} = HourlyAggregate.aggregate_hours(hours_ago(72), hours_ago(36))

      from = hours_ago(72)
      to = DateTime.utc_now() |> DateTime.truncate(:second)
      opts = [from: from, to: to]

      hybrid = StatsQueries.breakdown_by_model(nil, opts)
      assert Enum.map(hybrid, & &1.request_count) == [3]

      assert Decimal.compare(
               Enum.reduce(hybrid, Decimal.new(0), &Decimal.add(&1.cost_usd, &2)),
               Decimal.new("7.000000")
             ) == :eq

      assert StatsQueries.summary(%{from: from, to: to}).request_count == 3

      assert Decimal.compare(
               StatsQueries.summary(%{from: from, to: to}).total_cost_usd,
               Decimal.new("7.000000")
             ) == :eq

      assert Enum.map(StatsQueries.breakdown_by_group(opts), & &1.request_count) == [3]
      assert Enum.map(StatsQueries.breakdown_by_user(opts), & &1.request_count) == [3]

      {batch_models, _batch_members} =
        StatsQueries.breakdown_by_model_and_member(opts ++ [user_ids: [member.user_id]])

      assert Enum.map(batch_models, & &1.request_count) == [3]
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
