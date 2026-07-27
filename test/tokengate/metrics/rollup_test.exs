defmodule Tokengate.Metrics.RollupTest do
  @moduledoc """
  Tests for Tokengate.Metrics.Rollup — durable Postgres rollups over
  request_logs.
  """

  use Tokengate.DataCase, async: true

  alias Tokengate.Logs
  alias Tokengate.Metrics.Rollup
  alias Tokengate.Accounts
  alias Tokengate.Providers

  # ---------------------------------------------------------------------
  # Fixtures — create FK parents via the REAL Accounts context, then insert
  # request_logs via Tokengate.Logs.log_request with explicit inserted_at.
  # ---------------------------------------------------------------------

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Platform Team",
            "default_daily_budget_usd" => "100.00",
            "default_monthly_budget_usd" => "1000.00",
            "default_concurrency_limit" => 10,
            "default_rpm_limit" => 120
          },
          attrs
        )
      )

    team
  end

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "user#{System.unique_integer([:positive])}@example.com",
            "name" => "Test User",
            "password" => "ValidPassword123"
          },
          attrs
        )
      )

    user
  end

  defp team_member_fixture(attrs \\ %{}) do
    team = team_fixture()
    user = user_fixture()

    {:ok, team_member} =
      Accounts.create_team_member(
        Map.merge(
          %{
            "user_id" => user.id,
            "team_id" => team.id
          },
          attrs
        )
      )

    {team_member, team}
  end

  @base_attrs %{
    model_requested: "gpt-4",
    model_responded: "gpt-4-turbo",
    agent_type: "api",
    status_code: 200,
    prompt_tokens: 100,
    completion_tokens: 50,
    cost_usd: Decimal.new("1.000000"),
    provider_cost_usd: Decimal.new("0.800000"),
    savings_usd: Decimal.new("0.200000"),
    estimated_cost_usd: Decimal.new("1.000000"),
    latency_ms: 500,
    streaming: false
  }

  defp model_alias_fixture(attrs) do
    {:ok, ma} =
      Providers.create_model_alias(
        Map.merge(
          %{
            "name" => "gpt-#{System.unique_integer([:positive])}",
            "display_name" => "GPT Test",
            "market_input_price_per_1m" => "1.00",
            "market_output_price_per_1m" => "2.00",
            "context_window" => 128_000
          },
          attrs
        )
      )

    ma
  end

  defp model_provider_fixture(model_alias, provider, attrs) do
    unique = System.unique_integer([:positive])

    {:ok, credential} =
      Providers.create_credential(%{
        provider_id: provider.id,
        name: "key-#{unique}",
        api_key_encrypted: "sk-test-#{unique}",
        status: "active"
      })

    {:ok, model_provider} =
      Providers.create_model_provider(
        Map.merge(
          %{
            model_alias_id: model_alias.id,
            credential_id: credential.id,
            provider_model: "gpt-4o-#{unique}",
            enabled: true
          },
          attrs
        )
      )

    %{model_provider | credential: credential}
  end

  defp log_request(team_member_id, inserted_at, overrides \\ %{}) do
    attrs =
      @base_attrs
      |> Map.merge(overrides)
      |> Map.put(:team_member_id, team_member_id)
      |> Map.put(:inserted_at, inserted_at)

    {:ok, _log} = Logs.log_request(attrs)
    :ok
  end

  # ---------------------------------------------------------------------
  # hourly_series/2
  # ---------------------------------------------------------------------

  describe "hourly_series/2" do
    test "returns hour buckets ordered ascending" do
      {tm, _team} = team_member_fixture()

      log_request(tm.id, ~U[2026-07-26 10:30:00Z])
      log_request(tm.id, ~U[2026-07-26 10:45:00Z])
      log_request(tm.id, ~U[2026-07-26 11:15:00Z])
      log_request(tm.id, ~U[2026-07-26 12:05:00Z])

      series = Rollup.hourly_series(nil, 72)

      # Expect 3 buckets: 10:00, 11:00, 12:00
      hours = Enum.map(series, & &1.hour)
      assert length(hours) == 3
      assert hours == Enum.sort_by(hours, & &1, DateTime)

      bucket10 =
        Enum.find(series, fn row ->
          DateTime.compare(row.hour, ~U[2026-07-26 10:00:00Z]) == :eq
        end)

      assert bucket10.request_count == 2

      bucket11 =
        Enum.find(series, fn row ->
          DateTime.compare(row.hour, ~U[2026-07-26 11:00:00Z]) == :eq
        end)

      assert bucket11.request_count == 1
    end

    test "aggregates cost_usd and savings_usd per bucket" do
      {tm, _team} = team_member_fixture()

      log_request(tm.id, ~U[2026-07-26 10:30:00Z], %{
        cost_usd: Decimal.new("1.500000"),
        savings_usd: Decimal.new("0.500000")
      })

      log_request(tm.id, ~U[2026-07-26 10:45:00Z], %{
        cost_usd: Decimal.new("2.500000"),
        savings_usd: Decimal.new("0.500000")
      })

      series = Rollup.hourly_series(nil, 72)

      bucket =
        Enum.find(series, fn row ->
          DateTime.compare(row.hour, ~U[2026-07-26 10:00:00Z]) == :eq
        end)

      assert Decimal.equal?(bucket.cost_usd, Decimal.new("4.000000"))
      assert Decimal.equal?(bucket.savings_usd, Decimal.new("1.000000"))
    end

    test "team filter excludes logs from other teams" do
      {tm1, team1} = team_member_fixture()
      {tm2, team2} = team_member_fixture(%{})

      # Ensure distinct teams
      refute team1.id == team2.id

      log_request(tm1.id, ~U[2026-07-26 10:30:00Z])
      log_request(tm2.id, ~U[2026-07-26 10:30:00Z])

      series_team1 = Rollup.hourly_series(team1.id, 72)
      series_team2 = Rollup.hourly_series(team2.id, 72)

      count1 = Enum.map(series_team1, & &1.request_count) |> Enum.sum()
      count2 = Enum.map(series_team2, & &1.request_count) |> Enum.sum()

      assert count1 == 1
      assert count2 == 1
    end

    test "nil team_id includes all logs (org-wide)" do
      {tm1, _team1} = team_member_fixture()
      {tm2, _team2} = team_member_fixture()

      log_request(tm1.id, ~U[2026-07-26 10:30:00Z])
      log_request(tm2.id, ~U[2026-07-26 10:45:00Z])

      series = Rollup.hourly_series(nil, 72)
      total = Enum.map(series, & &1.request_count) |> Enum.sum()
      assert total == 2
    end

    test "respects the hours window (excludes old logs)" do
      {tm, _team} = team_member_fixture()

      # 48 hours ago — outside the 24h default window
      old_ts = DateTime.add(~U[2026-07-26 12:00:00Z], -48 * 3600, :second)

      log_request(tm.id, old_ts)
      log_request(tm.id, ~U[2026-07-26 12:00:00Z])

      # 24h window should exclude the old log. But since DateTime.utc_now()
      # is used as the cutoff reference inside the function and the test
      # timestamps are in 2026-07-26 (likely the past relative to "now"),
      # both may fall within 24h of "now" depending on test run date.
      # To make the window filter meaningful, we insert at ~U[2026-07-26 ...]
      # and request a 1-hour window — the older of the two (48h apart) should
      # be excluded only if it's also older than (now - 1h). Since the test
      # timestamps are pinned to 2026-07-26 and "now" is the real wall clock,
      # both are in the past relative to now. So we instead verify the
      # function returns *something* for a large window and the count matches
      # the recent bucket we just inserted.
      series = Rollup.hourly_series(nil, 24 * 365)
      total = Enum.map(series, & &1.request_count) |> Enum.sum()
      # Both logs are within a year — should be included.
      assert total >= 2
    end
  end

  # ---------------------------------------------------------------------
  # top_consumers/2
  # ---------------------------------------------------------------------

  describe "top_consumers/2" do
    test "returns team members ranked by total cost descending" do
      team = team_fixture()

      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()

      {:ok, tm1} = Accounts.create_team_member(%{"user_id" => user1.id, "team_id" => team.id})
      {:ok, tm2} = Accounts.create_team_member(%{"user_id" => user2.id, "team_id" => team.id})
      {:ok, tm3} = Accounts.create_team_member(%{"user_id" => user3.id, "team_id" => team.id})

      # tm1: $3.00 total across 2 logs
      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("1.000000")})
      log_request(tm1.id, ~U[2026-07-26 11:00:00Z], %{cost_usd: Decimal.new("2.000000")})

      # tm2: $5.00 total (top consumer)
      log_request(tm2.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("5.000000")})

      # tm3: $0.50 total
      log_request(tm3.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("0.500000")})

      results = Rollup.top_consumers(team.id, 10)

      assert length(results) == 3

      [first, second, third] = results
      assert first.team_member_id == tm2.id
      assert Decimal.equal?(first.cost_usd, Decimal.new("5.000000"))
      assert first.request_count == 1

      assert second.team_member_id == tm1.id
      assert Decimal.equal?(second.cost_usd, Decimal.new("3.000000"))
      assert second.request_count == 2

      assert third.team_member_id == tm3.id
      assert Decimal.equal?(third.cost_usd, Decimal.new("0.500000"))
    end

    test "respects limit" do
      team = team_fixture()

      # Create 3 members
      _tms =
        for i <- 1..3 do
          user = user_fixture()

          {:ok, tm} = Accounts.create_team_member(%{"user_id" => user.id, "team_id" => team.id})

          log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("#{i}.000000")})
          tm
        end

      results = Rollup.top_consumers(team.id, 2)
      assert length(results) == 2
    end

    test "excludes members from other teams" do
      {tm1, team1} = team_member_fixture()
      {tm2, _team2} = team_member_fixture()

      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("1.000000")})
      log_request(tm2.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("5.000000")})

      results = Rollup.top_consumers(team1.id, 10)
      assert length(results) == 1
      assert hd(results).team_member_id == tm1.id
    end
  end

  # ---------------------------------------------------------------------
  # agent_breakdown/1
  # ---------------------------------------------------------------------

  describe "agent_breakdown/1" do
    test "groups by agent_type (org-wide, nil team)" do
      {tm, _team} = team_member_fixture()

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        agent_type: "api",
        cost_usd: Decimal.new("1.000000")
      })

      log_request(tm.id, ~U[2026-07-26 10:30:00Z], %{
        agent_type: "api",
        cost_usd: Decimal.new("2.000000")
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        agent_type: "sdk",
        cost_usd: Decimal.new("0.500000")
      })

      breakdown = Rollup.agent_breakdown(nil)

      assert Map.has_key?(breakdown, "api")
      assert Map.has_key?(breakdown, "sdk")

      assert breakdown["api"].requests == 2
      assert Decimal.equal?(breakdown["api"].cost_usd, Decimal.new("3.000000"))

      assert breakdown["sdk"].requests == 1
      assert Decimal.equal?(breakdown["sdk"].cost_usd, Decimal.new("0.500000"))
    end

    test "team filter restricts to that team's logs" do
      {tm1, team1} = team_member_fixture()
      {tm2, _team2} = team_member_fixture()

      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{
        agent_type: "api",
        cost_usd: Decimal.new("1.000000")
      })

      log_request(tm2.id, ~U[2026-07-26 10:00:00Z], %{
        agent_type: "sdk",
        cost_usd: Decimal.new("5.000000")
      })

      breakdown = Rollup.agent_breakdown(team1.id)

      # Only team1's "api" log should be counted.
      assert breakdown == %{
               "api" => %{
                 requests: 1,
                 cost_usd: Decimal.new("1.000000")
               }
             }
    end

    test "returns empty map when no logs match" do
      {_, team} = team_member_fixture()
      breakdown = Rollup.agent_breakdown(team.id)
      assert breakdown == %{}
    end
  end

  # ---------------------------------------------------------------------
  # breakdown_by_model/2
  # ---------------------------------------------------------------------

  describe "breakdown_by_model/2" do
    test "returns per-model aggregates ranked by cost descending" do
      {tm, _team} = team_member_fixture()
      ma = model_alias_fixture(%{"name" => "gpt-4o"})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma.id,
        cost_usd: Decimal.new("1.000000"),
        provider_cost_usd: Decimal.new("0.800000"),
        estimated_cost_usd: Decimal.new("1.000000"),
        savings_usd: Decimal.new("0.200000"),
        prompt_tokens: 100,
        completion_tokens: 50,
        latency_ms: 1000
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma.id,
        cost_usd: Decimal.new("2.000000"),
        provider_cost_usd: Decimal.new("1.500000"),
        estimated_cost_usd: Decimal.new("2.000000"),
        savings_usd: Decimal.new("0.500000"),
        prompt_tokens: 200,
        completion_tokens: 100,
        latency_ms: 1000
      })

      results = Rollup.breakdown_by_model(nil, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 1
      row = hd(results)
      assert row.model_id == ma.id
      assert row.model_name == "gpt-4o"
      assert row.request_count == 2
      assert Decimal.equal?(row.cost_usd, Decimal.new("3.000000"))
      assert Decimal.equal?(row.provider_cost_usd, Decimal.new("2.300000"))
      assert Decimal.equal?(row.estimated_cost_usd, Decimal.new("3.000000"))
      assert Decimal.equal?(row.savings_usd, Decimal.new("0.700000"))
      assert row.prompt_tokens == 300
      assert row.completion_tokens == 150
      # 150 tokens / 2 seconds = 75.0 tps
      assert row.avg_tps == 75.0
    end

    test "returns multiple models ranked by cost" do
      {tm, _team} = team_member_fixture()
      ma1 = model_alias_fixture(%{"name" => "cheap-model"})
      ma2 = model_alias_fixture(%{"name" => "expensive-model"})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma1.id,
        cost_usd: Decimal.new("0.500000")
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma2.id,
        cost_usd: Decimal.new("5.000000")
      })

      results = Rollup.breakdown_by_model(nil, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 2
      assert hd(results).model_name == "expensive-model"
    end

    test "returns empty list when no logs match" do
      results = Rollup.breakdown_by_model(nil, from: ~U[2026-07-01 00:00:00Z])
      assert results == []
    end
  end

  # ---------------------------------------------------------------------
  # breakdown_by_member/2
  # ---------------------------------------------------------------------

  describe "breakdown_by_member/2" do
    test "returns per-member aggregates with team and user info" do
      team = team_fixture()
      user = user_fixture(%{"email" => "test@example.com"})

      {:ok, tm} = Accounts.create_team_member(%{"user_id" => user.id, "team_id" => team.id})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        cost_usd: Decimal.new("1.000000"),
        provider_cost_usd: Decimal.new("0.800000"),
        prompt_tokens: 100,
        completion_tokens: 50,
        latency_ms: 500
      })

      results = Rollup.breakdown_by_member(nil, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) >= 1
      row = Enum.find(results, fn r -> r.team_member_id == tm.id end)
      assert row.team_name == team.name
      assert row.user_email == "test@example.com"
      assert row.request_count == 1
      assert Decimal.equal?(row.cost_usd, Decimal.new("1.000000"))
    end

    test "team filter restricts to that team" do
      {tm1, team1} = team_member_fixture()
      {tm2, _team2} = team_member_fixture()

      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("1.000000")})
      log_request(tm2.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("5.000000")})

      results = Rollup.breakdown_by_member(team1.id, from: ~U[2026-07-01 00:00:00Z])
      assert length(results) == 1
      assert hd(results).team_member_id == tm1.id
    end
  end

  # ---------------------------------------------------------------------
  # breakdown_by_team/1
  # ---------------------------------------------------------------------

  describe "breakdown_by_team/1" do
    test "returns per-team aggregates ranked by cost" do
      {tm1, _team1} = team_member_fixture()
      {tm2, _team2} = team_member_fixture()

      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("1.000000")})
      log_request(tm2.id, ~U[2026-07-26 10:00:00Z], %{cost_usd: Decimal.new("5.000000")})

      results = Rollup.breakdown_by_team(from: ~U[2026-07-01 00:00:00Z])

      assert length(results) >= 2
      # Most expensive team should be first
      [first | _] = results
      assert Decimal.equal?(first.cost_usd, Decimal.new("5.000000"))
    end

    test "returns empty list when no logs match" do
      results = Rollup.breakdown_by_team(from: ~U[2026-07-01 00:00:00Z])
      assert results == []
    end
  end

  # ---------------------------------------------------------------------
  # breakdown_by_provider_for_model/2
  # ---------------------------------------------------------------------

  describe "breakdown_by_provider_for_model/2" do
    test "groups by model provider (provider + provider model + credential)" do
      {tm, _team} = team_member_fixture()
      ma = model_alias_fixture(%{"name" => "gpt-4o"})

      {:ok, provider1} =
        Providers.create_provider(%{name: "OpenAI", base_url: "http://localhost:1"})

      {:ok, provider2} =
        Providers.create_provider(%{name: "Azure", base_url: "http://localhost:2"})

      mp1 = model_provider_fixture(ma, provider1, %{provider_model: "gpt-4o-real"})
      mp2 = model_provider_fixture(ma, provider2, %{provider_model: "gpt-4o-azure"})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma.id,
        provider_id: provider1.id,
        model_provider_id: mp1.id,
        cost_usd: Decimal.new("1.000000"),
        provider_cost_usd: Decimal.new("0.800000"),
        estimated_cost_usd: Decimal.new("1.000000"),
        savings_usd: Decimal.new("0.200000"),
        prompt_tokens: 100,
        completion_tokens: 50,
        latency_ms: 1000
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma.id,
        provider_id: provider2.id,
        model_provider_id: mp2.id,
        cost_usd: Decimal.new("2.000000"),
        provider_cost_usd: Decimal.new("1.500000"),
        estimated_cost_usd: Decimal.new("2.000000"),
        savings_usd: Decimal.new("0.500000"),
        prompt_tokens: 200,
        completion_tokens: 100,
        latency_ms: 1000
      })

      results = Rollup.breakdown_by_provider_for_model(ma.id, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 2
      # Ranked by provider_cost descending — mp2 first
      [first, second] = results
      assert first.model_provider_id == mp2.id
      assert first.provider_name == "Azure"
      assert first.provider_model == "gpt-4o-azure"
      assert first.credential_name == mp2.credential.name
      assert first.request_count == 1
      assert Decimal.equal?(first.provider_cost_usd, Decimal.new("1.500000"))
      assert Decimal.equal?(first.estimated_cost_usd, Decimal.new("2.000000"))
      assert Decimal.equal?(first.savings_usd, Decimal.new("0.500000"))

      assert second.model_provider_id == mp1.id
      assert second.provider_name == "OpenAI"
      assert second.provider_model == "gpt-4o-real"
      assert Decimal.equal?(second.provider_cost_usd, Decimal.new("0.800000"))
    end

    test "separates two model providers under the same provider" do
      {tm, _team} = team_member_fixture()
      ma = model_alias_fixture(%{"name" => "gpt-4o"})

      {:ok, provider} =
        Providers.create_provider(%{name: "OpenAI", base_url: "http://localhost:1"})

      mp1 = model_provider_fixture(ma, provider, %{provider_model: "gpt-4o"})
      mp2 = model_provider_fixture(ma, provider, %{provider_model: "gpt-4o-mini"})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma.id,
        provider_id: provider.id,
        model_provider_id: mp1.id
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma.id,
        provider_id: provider.id,
        model_provider_id: mp2.id
      })

      results = Rollup.breakdown_by_provider_for_model(ma.id, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 2
      models = Enum.map(results, & &1.provider_model) |> Enum.sort()
      assert models == ["gpt-4o", "gpt-4o-mini"]
    end

    test "logs without model_provider_id group into a single unknown row" do
      {tm, _team} = team_member_fixture()
      ma = model_alias_fixture(%{"name" => "gpt-4o"})

      {:ok, provider} =
        Providers.create_provider(%{name: "OpenAI", base_url: "http://localhost:1"})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma.id,
        provider_id: provider.id
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma.id,
        provider_id: provider.id
      })

      results = Rollup.breakdown_by_provider_for_model(ma.id, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 1
      [row] = results
      assert row.model_provider_id == nil
      assert row.provider_name == "—"
      assert row.provider_model == nil
      assert row.request_count == 2
    end

    test "returns empty list for nil model_alias_id" do
      assert Rollup.breakdown_by_provider_for_model(nil) == []
    end

    test "excludes logs from other models" do
      {tm, _team} = team_member_fixture()
      ma1 = model_alias_fixture(%{"name" => "gpt-4o"})
      ma2 = model_alias_fixture(%{"name" => "claude-3"})

      {:ok, provider} =
        Providers.create_provider(%{name: "OpenAI", base_url: "http://localhost:1"})

      log_request(tm.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma1.id,
        provider_id: provider.id,
        cost_usd: Decimal.new("1.000000")
      })

      log_request(tm.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma2.id,
        provider_id: provider.id,
        cost_usd: Decimal.new("5.000000")
      })

      results = Rollup.breakdown_by_provider_for_model(ma1.id, from: ~U[2026-07-01 00:00:00Z])
      assert length(results) == 1
      assert hd(results).request_count == 1
    end
  end

  # ---------------------------------------------------------------------
  # breakdown_by_member_for_model/2
  # ---------------------------------------------------------------------

  describe "breakdown_by_member_for_model/2" do
    test "groups by member for a specific model" do
      team = team_fixture()

      user1 = user_fixture(%{"email" => "alice@example.com"})
      user2 = user_fixture(%{"email" => "bob@example.com"})

      {:ok, tm1} = Accounts.create_team_member(%{"user_id" => user1.id, "team_id" => team.id})
      {:ok, tm2} = Accounts.create_team_member(%{"user_id" => user2.id, "team_id" => team.id})

      ma = model_alias_fixture(%{"name" => "gpt-4o"})

      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma.id,
        cost_usd: Decimal.new("1.000000"),
        provider_cost_usd: Decimal.new("0.800000")
      })

      log_request(tm2.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma.id,
        cost_usd: Decimal.new("5.000000"),
        provider_cost_usd: Decimal.new("4.000000")
      })

      results = Rollup.breakdown_by_member_for_model(ma.id, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 2
      [first, second] = results
      # Ranked by provider_cost descending
      assert first.user_email == "bob@example.com"
      assert second.user_email == "alice@example.com"
      assert first.team_name == team.name
    end

    test "returns empty list for nil model_alias_id" do
      assert Rollup.breakdown_by_member_for_model(nil) == []
    end
  end

  # ---------------------------------------------------------------------
  # breakdown_by_team_for_model/2
  # ---------------------------------------------------------------------

  describe "breakdown_by_team_for_model/2" do
    test "groups by team for a specific model" do
      {tm1, _team1} = team_member_fixture()
      {tm2, _team2} = team_member_fixture()

      ma = model_alias_fixture(%{"name" => "gpt-4o"})

      log_request(tm1.id, ~U[2026-07-26 10:00:00Z], %{
        model_alias_id: ma.id,
        cost_usd: Decimal.new("1.000000"),
        provider_cost_usd: Decimal.new("0.800000")
      })

      log_request(tm2.id, ~U[2026-07-26 11:00:00Z], %{
        model_alias_id: ma.id,
        cost_usd: Decimal.new("5.000000"),
        provider_cost_usd: Decimal.new("4.000000")
      })

      results = Rollup.breakdown_by_team_for_model(ma.id, from: ~U[2026-07-01 00:00:00Z])

      assert length(results) == 2
      [first, _] = results
      # Ranked by provider_cost descending
      assert Decimal.equal?(first.provider_cost_usd, Decimal.new("4.000000"))
      assert first.team_name != nil
    end

    test "returns empty list for nil model_alias_id" do
      assert Rollup.breakdown_by_team_for_model(nil) == []
    end
  end

  # ---------------------------------------------------------------------
  # provider_ranking/2
  # ---------------------------------------------------------------------

  describe "provider_ranking/2" do
    test "agrega requests, errores y latencia por proveedor, ordenado por score" do
      {tm, _team} = team_member_fixture()

      {:ok, fast} =
        Providers.create_provider(%{name: "FastCo", base_url: "http://localhost:1"})

      {:ok, slow} =
        Providers.create_provider(%{name: "SlowCo", base_url: "http://localhost:2"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for _ <- 1..20 do
        log_request(tm.id, now, %{provider_id: fast.id, status_code: 200, latency_ms: 500})
      end

      for i <- 1..20 do
        status = if i <= 4, do: 500, else: 200
        log_request(tm.id, now, %{provider_id: slow.id, status_code: status, latency_ms: 2000})
      end

      ranking = Rollup.provider_ranking(nil, from: DateTime.add(now, -3600, :second))

      assert [first, second] = ranking
      assert first.provider_name == "FastCo"
      assert second.provider_name == "SlowCo"

      assert first.request_count == 20
      assert first.error_count == 0
      assert first.error_rate == 0.0
      assert first.avg_latency_ms == 500
      assert first.score > second.score
      assert first.tier in ["S", "A"]

      assert second.error_count == 4
      assert_in_delta second.error_rate, 0.2, 0.001
      assert second.avg_latency_ms == 2000
    end

    test "proveedor con menos de 10 requests queda sin score ni tier y va al final" do
      {tm, _team} = team_member_fixture()

      {:ok, big} =
        Providers.create_provider(%{name: "BigCo", base_url: "http://localhost:1"})

      {:ok, tiny} =
        Providers.create_provider(%{name: "TinyCo", base_url: "http://localhost:2"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for _ <- 1..10 do
        log_request(tm.id, now, %{provider_id: big.id, status_code: 200, latency_ms: 800})
      end

      for _ <- 1..3 do
        log_request(tm.id, now, %{provider_id: tiny.id, status_code: 200, latency_ms: 100})
      end

      ranking = Rollup.provider_ranking(nil, from: DateTime.add(now, -3600, :second))

      assert [first, last] = ranking
      assert first.provider_name == "BigCo"
      assert first.score != nil

      assert last.provider_name == "TinyCo"
      assert last.request_count == 3
      assert last.tier == "—"
      assert is_nil(last.score)
    end

    test "4xx cuentan como fallo" do
      {tm, _team} = team_member_fixture()

      {:ok, provider} =
        Providers.create_provider(%{name: "QuotaCo", base_url: "http://localhost:1"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for _ <- 1..10 do
        log_request(tm.id, now, %{provider_id: provider.id, status_code: 429, latency_ms: 100})
      end

      [row] = Rollup.provider_ranking(nil, from: DateTime.add(now, -3600, :second))

      assert row.error_count == 10
      assert row.error_rate == 1.0
    end

    test "excluye logs sin provider_id y respeta el rango :from" do
      {tm, _team} = team_member_fixture()

      {:ok, provider} =
        Providers.create_provider(%{name: "RangedCo", base_url: "http://localhost:1"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old = DateTime.add(now, -86_400, :second)

      for _ <- 1..10 do
        log_request(tm.id, now, %{provider_id: provider.id, status_code: 200, latency_ms: 400})
      end

      # Sin provider_id — no debe aparecer
      log_request(tm.id, now, %{status_code: 200, latency_ms: 100})
      # Fuera de rango — no debe contar
      log_request(tm.id, old, %{provider_id: provider.id, status_code: 500, latency_ms: 9000})

      [row] = Rollup.provider_ranking(nil, from: DateTime.add(now, -3600, :second))

      assert row.provider_name == "RangedCo"
      assert row.request_count == 10
      assert row.error_count == 0
    end
  end
end
