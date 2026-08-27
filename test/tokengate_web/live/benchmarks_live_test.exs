defmodule TokengateWeb.BenchmarksLiveTest do
  @moduledoc """
  Tests for the Providers Benchmarks report page — built from request_logs,
  one row per provider (never per credential/API key).
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "bench-#{u}@example.com",
        name: "Bench #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp alias_fixture(name) do
    {:ok, ma} =
      Providers.create_model_alias(%{
        "name" => "#{name}-#{unique()}",
        "context_window" => 128_000,
        "model_type" => "llm"
      })

    ma
  end

  defp provider_fixture(name) do
    {:ok, provider} =
      Providers.create_provider(%{name: "#{name} #{unique()}", base_url: "http://localhost:1"})

    provider
  end

  defp seed_alias_with_usage do
    ma = alias_fixture("gpt-4o")
    fast = provider_fixture("FastCo")
    slow = provider_fixture("SlowCo")

    {:ok, team} = Accounts.create_team(%{name: "Bench Team #{unique()}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "bench-owner-#{unique()}@example.com",
        name: "Owner",
        password: "password-secret-1"
      })

    {:ok, member} = Accounts.create_team_member(%{user_id: owner.id, team_id: team.id})

    # FastCo: 2 requests, 0 errors
    {:ok, _} =
      Logs.log_request(%{
        team_member_id: member.id,
        model_alias_id: ma.id,
        provider_id: fast.id,
        model_requested: "gpt-4o-fast",
        status_code: 200,
        ttft_ms: 150,
        latency_ms: 400,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: Decimal.new("0.010000")
      })

    {:ok, _} =
      Logs.log_request(%{
        team_member_id: member.id,
        model_alias_id: ma.id,
        provider_id: fast.id,
        model_requested: "gpt-4o-fast",
        status_code: 200,
        ttft_ms: 250,
        latency_ms: 600,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: Decimal.new("0.020000")
      })

    # SlowCo: 1 request with error
    {:ok, _} =
      Logs.log_request(%{
        team_member_id: member.id,
        model_alias_id: ma.id,
        provider_id: slow.id,
        model_requested: "gpt-4o-slow",
        status_code: 500,
        ttft_ms: nil,
        latency_ms: 900,
        prompt_tokens: 80,
        completion_tokens: 0,
        error_reason: "upstream_error",
        provider_cost_usd: Decimal.new("0.000000")
      })

    %{alias: ma, fast: fast, slow: slow}
  end

  describe "admin access" do
    test "page renders model selector and period picker", %{conn: conn} do
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, html} = live(conn, ~p"/dashboard/benchmarks")

      assert html =~ "Providers Benchmarks"
      assert has_element?(view, "#alias-form")
      assert has_element?(view, "#period-picker")
      assert html =~ "Ventana"
    end

    test "non-admin is redirected", %{conn: conn} do
      %{user: user, password: pass} = register("user")
      conn = login(conn, user, pass)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/dashboard/benchmarks")
      assert to == "/dashboard"
    end
  end

  describe "provider report" do
    test "selecting a model shows one row per provider with aggregates", %{conn: conn} do
      %{alias: ma, fast: fast, slow: slow} = seed_alias_with_usage()
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/benchmarks")

      html =
        view
        |> element("#alias-form")
        |> render_change(%{alias_id: ma.id})

      # One row per provider — provider names appear, credential/API-key
      # columns never do.
      assert html =~ "FastCo"
      assert html =~ "SlowCo"
      refute html =~ "Credencial"
      refute html =~ "API Key"
      refute html =~ "Correr benchmarks"

      # Summary strip reflects the seeded usage (3 requests total).
      assert html =~ "Proveedores activos"
      assert has_element?(view, "#benchmark-report")
      assert has_element?(view, "#provider-row-#{fast.id}")
      assert has_element?(view, "#provider-row-#{slow.id}")
    end

    test "period switch reloads the report", %{conn: conn} do
      %{alias: ma} = seed_alias_with_usage()
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/benchmarks")

      view |> element("#alias-form") |> render_change(%{alias_id: ma.id})
      html = view |> element("button[phx-value-period='7d']") |> render_click()

      assert html =~ "FastCo"
      assert html =~ "7 días"
    end

    test "model without usage shows empty state", %{conn: conn} do
      ma = alias_fixture("unused-model")
      %{user: admin, password: pass} = register("admin")
      conn = login(conn, admin, pass)
      {:ok, view, _html} = live(conn, ~p"/dashboard/benchmarks")

      html =
        view
        |> element("#alias-form")
        |> render_change(%{alias_id: ma.id})

      assert html =~ "Sin uso registrado"
    end
  end
end
