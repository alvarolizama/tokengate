defmodule Tokengate.LogsTest do
  use Tokengate.DataCase, async: true

  alias Tokengate.Logs
  alias Tokengate.Accounts

  # ---------------------------------------------------------------------------
  # Fixtures — create FK parents via the REAL Accounts/Providers contexts.
  # ---------------------------------------------------------------------------

  defp valid_team_attrs(attrs) do
    Map.merge(
      %{
        "name" => "Platform Team",
        "monthly_budget_per_user_usd" => "100.00",
        "default_concurrency_limit" => 10,
        "default_rpm_limit" => 120
      },
      attrs
    )
  end

  defp team_fixture(attrs \\ %{}) do
    {:ok, team} = Accounts.create_team(valid_team_attrs(attrs))
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

  @timestamp ~U[2026-07-26 12:00:00Z]

  defp log_fixture(attrs \\ %{}) do
    {team_member, _team} = team_member_fixture()

    default_attrs = %{
      team_member_id: team_member.id,
      model_requested: "gpt-4",
      model_responded: "gpt-4-turbo",
      agent_type: "api",
      status_code: 200,
      prompt_tokens: 100,
      completion_tokens: 50,
      cost_usd: Decimal.new("1.500000"),
      provider_cost_usd: Decimal.new("1.000000"),
      savings_usd: Decimal.new("0.500000"),
      estimated_cost_usd: Decimal.new("1.500000"),
      latency_ms: 500,
      streaming: false,
      inserted_at: @timestamp
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, log} = Logs.log_request(attrs)
    {log, team_member}
  end

  # ---------------------------------------------------------------------------
  # log_request/1
  # ---------------------------------------------------------------------------

  describe "log_request/1" do
    test "inserts a request log and returns it" do
      {log, _team_member} = log_fixture()

      assert log.id
      assert log.team_member_id
      assert log.model_requested == "gpt-4"
      assert log.model_responded == "gpt-4-turbo"
      assert log.agent_type == "api"
      assert log.status_code == 200
      assert log.prompt_tokens == 100
      assert log.completion_tokens == 50
      assert Decimal.equal?(log.cost_usd, Decimal.new("1.500000"))
      assert log.streaming == false
      assert log.inserted_at == @timestamp
    end

    test "lands in a real partition and is queryable" do
      {log, _team_member} = log_fixture(%{inserted_at: ~U[2026-07-26 15:30:00Z]})

      # Query directly via Repo — should find the row
      result = Logs.list_logs(%{team_member_id: log.team_member_id})
      assert length(result) == 1
      assert hd(result).id == log.id
    end

    test "generates id and inserted_at when not provided" do
      {team_member, _team} = team_member_fixture()

      before = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, log} =
        Logs.log_request(%{
          team_member_id: team_member.id,
          model_requested: "claude-3"
        })

      after_insert = DateTime.utc_now() |> DateTime.truncate(:second)

      assert log.id
      # inserted_at should be between before and after
      assert DateTime.compare(log.inserted_at, before) in [:gt, :eq]
      assert DateTime.compare(log.inserted_at, after_insert) in [:lt, :eq]
    end

    test "applies defaults for agent_type, tokens, and streaming" do
      {team_member, _team} = team_member_fixture()

      {:ok, log} =
        Logs.log_request(%{
          team_member_id: team_member.id,
          model_requested: "test-model"
        })

      assert log.agent_type == "unknown"
      assert log.prompt_tokens == 0
      assert log.completion_tokens == 0
      assert log.streaming == false
    end

    test "requires team_member_id and model_requested" do
      {:error, changeset} = Logs.log_request(%{})

      assert errors_on(changeset).team_member_id
      assert errors_on(changeset).model_requested
    end

    test "never stores prompt or completion content — metadata only" do
      {log, _team_member} = log_fixture()

      # The struct should not have any content fields
      refute Map.has_key?(log, :prompt)
      refute Map.has_key?(log, :completion)
      refute Map.has_key?(log, :request_body)
      refute Map.has_key?(log, :response_body)
      refute Map.has_key?(log, :content)
    end
  end

  # ---------------------------------------------------------------------------
  # list_logs/1
  # ---------------------------------------------------------------------------

  describe "list_logs/1" do
    test "returns logs ordered by inserted_at DESC" do
      {log1, _} = log_fixture(%{inserted_at: ~U[2026-07-26 10:00:00Z]})
      {log2, _} = log_fixture(%{inserted_at: ~U[2026-07-26 12:00:00Z]})
      {log3, _} = log_fixture(%{inserted_at: ~U[2026-07-26 11:00:00Z]})

      logs = Logs.list_logs()
      ids = Enum.map(logs, & &1.id)

      # Most recent first
      assert ids == [log2.id, log3.id, log1.id]
    end

    test "filters by team_member_id" do
      {log1, _} = log_fixture()
      {log2, team_member2} = log_fixture(%{model_requested: "claude-3"})

      logs = Logs.list_logs(%{team_member_id: team_member2.id})

      assert length(logs) == 1
      assert hd(logs).id == log2.id
      refute Enum.any?(logs, &(&1.id == log1.id))
    end

    test "filters by agent_type" do
      {_log1, _} = log_fixture(%{agent_type: "api"})
      {_log2, _} = log_fixture(%{agent_type: "sdk"})

      logs = Logs.list_logs(%{agent_type: "sdk"})
      assert length(logs) == 1
      assert hd(logs).agent_type == "sdk"
    end

    test "filters by status_code" do
      {_log1, _} = log_fixture(%{status_code: 200})
      {_log2, _} = log_fixture(%{status_code: 500})

      logs = Logs.list_logs(%{status_code: 500})
      assert length(logs) == 1
      assert hd(logs).status_code == 500
    end

    test "filters by streaming" do
      {_log1, _} = log_fixture(%{streaming: false})
      {_log2, _} = log_fixture(%{streaming: true})

      logs = Logs.list_logs(%{streaming: true})
      assert length(logs) == 1
      assert hd(logs).streaming == true
    end

    test "filters by from/to inserted_at range" do
      {_log1, _} = log_fixture(%{inserted_at: ~U[2026-07-26 10:00:00Z]})
      {log2, _} = log_fixture(%{inserted_at: ~U[2026-07-26 12:00:00Z]})
      {_log3, _} = log_fixture(%{inserted_at: ~U[2026-07-26 14:00:00Z]})

      logs =
        Logs.list_logs(%{
          from: ~U[2026-07-26 11:00:00Z],
          to: ~U[2026-07-26 13:00:00Z]
        })

      assert length(logs) == 1
      assert hd(logs).id == log2.id
    end

    test "respects limit (default 50)" do
      {tm, _} = team_member_fixture()

      for i <- 1..10 do
        Logs.log_request(%{
          team_member_id: tm.id,
          model_requested: "model-#{i}",
          inserted_at: ~U[2026-07-26 12:00:00Z]
        })
      end

      # Default limit returns all 10 (under 50)
      assert length(Logs.list_logs(%{team_member_id: tm.id})) == 10

      # Explicit limit of 3
      assert length(Logs.list_logs(%{team_member_id: tm.id, limit: 3})) == 3
    end

    test "clamps limit to max 500" do
      {tm, _} = team_member_fixture()

      {:ok, _} =
        Logs.log_request(%{
          team_member_id: tm.id,
          model_requested: "model-1",
          inserted_at: ~U[2026-07-26 12:00:00Z]
        })

      # Requesting more than 500 should not raise — clamps to 500
      logs = Logs.list_logs(%{team_member_id: tm.id, limit: 1000})
      assert length(logs) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # list_logs_for_team/2
  # ---------------------------------------------------------------------------

  describe "list_logs_for_team/2" do
    test "returns logs entries for members of the specified team" do
      team1 = team_fixture()
      team2 = team_fixture(%{"name" => "Other Team"})

      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, tm1} = Accounts.create_team_member(%{"user_id" => user1.id, "team_id" => team1.id})
      {:ok, tm2} = Accounts.create_team_member(%{"user_id" => user2.id, "team_id" => team2.id})

      {:ok, _log1} =
        Logs.log_request(%{
          team_member_id: tm1.id,
          model_requested: "gpt-4",
          inserted_at: @timestamp
        })

      {:ok, _log2} =
        Logs.log_request(%{
          team_member_id: tm2.id,
          model_requested: "claude-3",
          inserted_at: @timestamp
        })

      # team1 should only see tm1's logs
      logs = Logs.list_logs_for_team(team1.id)
      assert length(logs) == 1
      assert hd(logs).team_member_id == tm1.id

      # team2 should only see tm2's logs
      logs = Logs.list_logs_for_team(team2.id)
      assert length(logs) == 1
      assert hd(logs).team_member_id == tm2.id
    end

    test "accepts additional filters" do
      team = team_fixture()
      user = user_fixture()

      {:ok, tm} = Accounts.create_team_member(%{"user_id" => user.id, "team_id" => team.id})

      {:ok, _} =
        Logs.log_request(%{
          team_member_id: tm.id,
          model_requested: "gpt-4",
          agent_type: "api",
          status_code: 200,
          inserted_at: @timestamp
        })

      {:ok, _} =
        Logs.log_request(%{
          team_member_id: tm.id,
          model_requested: "gpt-4",
          agent_type: "sdk",
          status_code: 500,
          inserted_at: @timestamp
        })

      # Filter by status_code
      logs = Logs.list_logs_for_team(team.id, %{status_code: 500})
      assert length(logs) == 1
      assert hd(logs).status_code == 500
    end
  end

  # ---------------------------------------------------------------------------
  # cost_summary/1
  # ---------------------------------------------------------------------------

  describe "cost_summary/1" do
    test "aggregates costs and tokens across matching logs" do
      {tm, _} = team_member_fixture()

      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd: Decimal.new("1.500000"),
        provider_cost_usd: Decimal.new("1.000000"),
        savings_usd: Decimal.new("0.500000"),
        estimated_cost_usd: Decimal.new("1.500000"),
        inserted_at: @timestamp
      })

      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        prompt_tokens: 200,
        completion_tokens: 100,
        cost_usd: Decimal.new("2.500000"),
        provider_cost_usd: Decimal.new("2.000000"),
        savings_usd: Decimal.new("0.500000"),
        estimated_cost_usd: Decimal.new("2.500000"),
        inserted_at: @timestamp
      })

      summary = Logs.cost_summary(%{team_member_id: tm.id})

      assert Decimal.equal?(summary.total_cost_usd, Decimal.new("4.000000"))
      assert Decimal.equal?(summary.total_provider_cost_usd, Decimal.new("3.000000"))
      assert Decimal.equal?(summary.total_savings_usd, Decimal.new("1.000000"))
      assert Decimal.equal?(summary.total_estimated_cost_usd, Decimal.new("4.000000"))
      assert summary.total_prompt_tokens == 300
      assert summary.total_completion_tokens == 150
      assert summary.request_count == 2
    end

    test "handles nil cost fields with Decimal-safe sums" do
      {tm, _} = team_member_fixture()

      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        prompt_tokens: 100,
        completion_tokens: 50,
        cost_usd: nil,
        provider_cost_usd: nil,
        savings_usd: nil,
        estimated_cost_usd: nil,
        inserted_at: @timestamp
      })

      summary = Logs.cost_summary(%{team_member_id: tm.id})

      assert Decimal.equal?(summary.total_cost_usd, Decimal.new("0"))
      assert Decimal.equal?(summary.total_provider_cost_usd, Decimal.new("0"))
      assert Decimal.equal?(summary.total_savings_usd, Decimal.new("0"))
      assert Decimal.equal?(summary.total_estimated_cost_usd, Decimal.new("0"))
      assert summary.total_prompt_tokens == 100
      assert summary.total_completion_tokens == 50
      assert summary.request_count == 1
    end

    test "returns zero counts when no logs match" do
      {tm, _} = team_member_fixture()

      summary = Logs.cost_summary(%{team_member_id: tm.id})

      assert Decimal.equal?(summary.total_cost_usd, Decimal.new("0"))
      assert summary.total_prompt_tokens == 0
      assert summary.total_completion_tokens == 0
      assert summary.request_count == 0
    end

    test "avg_ttft_ms averages only streaming rows (NULLs skipped)" do
      {tm, _} = team_member_fixture()

      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        latency_ms: 2000,
        ttft_ms: 300,
        streaming: true,
        inserted_at: @timestamp
      })

      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        latency_ms: 4000,
        ttft_ms: 500,
        streaming: true,
        inserted_at: @timestamp
      })

      # Non-streaming row: no ttft — must not affect the average.
      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        latency_ms: 9000,
        streaming: false,
        inserted_at: @timestamp
      })

      summary = Logs.cost_summary(%{team_member_id: tm.id})

      assert summary.avg_ttft_ms == 400.0
      assert summary.avg_latency_ms == 5000.0
    end

    test "avg_ttft_ms is nil when no streaming samples exist" do
      {tm, _} = team_member_fixture()

      Logs.log_request(%{
        team_member_id: tm.id,
        model_requested: "gpt-4",
        latency_ms: 1000,
        streaming: false,
        inserted_at: @timestamp
      })

      summary = Logs.cost_summary(%{team_member_id: tm.id})

      assert summary.avg_ttft_ms == nil
    end
  end

  describe "log_request/1 with ttft_ms" do
    test "persists ttft_ms for streaming requests" do
      {tm, _} = team_member_fixture()

      assert {:ok, log} =
               Logs.log_request(%{
                 team_member_id: tm.id,
                 model_requested: "gpt-4",
                 latency_ms: 1500,
                 ttft_ms: 250,
                 streaming: true,
                 inserted_at: @timestamp
               })

      assert log.ttft_ms == 250
    end
  end

  describe "realtime_summary/2" do
    defp recent(seconds_ago) do
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.truncate(:second)
    end

    test "counts only logs inside the rolling window" do
      {log1, tm} = log_fixture(%{inserted_at: recent(30), latency_ms: 400})
      {_log2, _} = log_fixture(%{inserted_at: recent(60), latency_ms: 600})
      # 1 hour ago — outside the default 5-minute window
      {_old, _} = log_fixture(%{inserted_at: recent(3600), latency_ms: 999})

      summary = Logs.realtime_summary(%{team_member_id: tm.id})

      assert summary.request_count == 1
      assert summary.avg_latency_ms == 400.0

      # unfiltered: 2 logs in window, 5 min window → 0.4 req/min
      unfiltered = Logs.realtime_summary()
      assert unfiltered.request_count >= 2
      assert_in_delta unfiltered.req_per_min, unfiltered.request_count / 5, 0.01
      assert log1.id
    end

    test "counts errors (status >= 400) and computes error rate" do
      {_ok, tm} = log_fixture(%{inserted_at: recent(10), status_code: 200})
      {_err, _} = log_fixture(%{inserted_at: recent(20), status_code: 500, team_member_id: tm.id})

      summary = Logs.realtime_summary(%{team_member_id: tm.id})

      assert summary.request_count == 2
      assert summary.error_count == 1
      assert summary.error_rate == 50.0
    end

    test "empty window returns zeros and nil latency" do
      summary = Logs.realtime_summary(%{team_member_id: Ecto.UUID.generate()})

      assert summary.request_count == 0
      assert summary.req_per_min == 0.0
      assert summary.error_count == 0
      assert summary.error_rate == 0.0
      assert summary.avg_latency_ms == nil
    end

    test "respects filters like status_class" do
      {_ok, tm} = log_fixture(%{inserted_at: recent(10), status_code: 200})
      {_err, _} = log_fixture(%{inserted_at: recent(20), status_code: 500, team_member_id: tm.id})

      summary = Logs.realtime_summary(%{team_member_id: tm.id, status_class: "2xx"})

      assert summary.request_count == 1
      assert summary.error_count == 0
    end

    test "accepts a custom window in seconds" do
      {_log, tm} = log_fixture(%{inserted_at: recent(600)})

      assert Logs.realtime_summary(%{team_member_id: tm.id}, 300).request_count == 0
      assert Logs.realtime_summary(%{team_member_id: tm.id}, 900).request_count == 1
    end
  end
end
