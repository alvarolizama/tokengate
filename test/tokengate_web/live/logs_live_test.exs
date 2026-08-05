defmodule TokengateWeb.LogsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Periods, Providers}
  alias Tokengate.Budgets.Manager
  alias Tokengate.Logs.Inflight

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "logs-#{u}@example.com",
        name: "Logs #{u}",
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

  defp broke_member_fixture(attrs \\ %{}) do
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(
        Map.merge(
          %{
            "name" => "Budget Team #{unique()}",
            "monthly_budget_per_user_usd" => "100.00"
          },
          attrs
        )
      )

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    {member, member_user, team}
  end

  defp log_spend(member_id, cost) do
    {:ok, _} =
      Logs.log_request(%{
        team_member_id: member_id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new(cost)
      })
  end

  defp member_with_log(opts \\ []) do
    u = unique()

    {:ok, team} = Accounts.create_team(%{name: "Logs Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "logs-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, model_alias} =
      Providers.create_model_alias(%{
        name: "model-#{u}",
        display_name: "Model #{u}",
        context_window: 128_000
      })

    {:ok, log} =
      Logs.log_request(%{
        team_member_id: member.id,
        provider_id: provider.id,
        model_requested: "model-#{u}",
        model_responded: "model-#{u}",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: "0.004",
        latency_ms: 42,
        streaming: false,
        think: Keyword.get(opts, :think, true),
        effort: Keyword.get(opts, :effort, "high"),
        api_key_prefix: "sk-logs-",
        credential_name: "Staging",
        inserted_at:
          Keyword.get(opts, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
      })

    %{team: team, owner: owner, member: member, log: log, model_alias: model_alias}
  end

  setup do
    pid = Process.whereis(Inflight) || start_supervised!(Inflight)
    _ = :sys.get_state(pid)

    for entry <- Inflight.list() do
      Inflight.finish_request(entry.id)
    end

    budget_pid = Process.whereis(Manager) || start_supervised!(Manager)
    _ = :sys.get_state(budget_pid)

    :ok
  end

  ## Auth ---------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/logs")
  end

  ## User / team / think / effort columns ---------------------------------------

  test "shows user, team, think and effort for completed logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{team: team, owner: owner} = member_with_log(think: true, effort: "high")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    html = render(view)
    assert html =~ owner.email
    assert html =~ team.name
    assert html =~ "high"
  end

  ## Pending (in-flight) rows ---------------------------------------------------

  test "pending request appears live and disappears when done", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member} = member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    entry =
      Inflight.start_request(%{
        team_member_id: member.id,
        user_email: "live@example.com",
        team_name: "Live Team",
        model_requested: "glm-5.2",
        agent_type: "api",
        streaming: true,
        think: true,
        effort: "high",
        provider_name: "Test Provider",
        api_key_prefix: "sk-live-",
        credential_name: "Producción"
      })

    html = render(view)
    assert html =~ "pending-row-#{entry.id}"
    assert html =~ "Pending"
    assert html =~ "live@example.com"

    Inflight.finish_request(entry.id)
    html = render(view)
    refute html =~ "pending-row-#{entry.id}"
  end

  test "pending respects model filter", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member, model_alias: model_alias} = member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    # Filtrar por el alias del test: el pending usa otro modelo y debe ocultarse
    view
    |> form("#logs-filter-form", filter: %{model_search: model_alias.name})
    |> render_change()

    entry =
      Inflight.start_request(%{
        team_member_id: member.id,
        model_requested: "glm-5.2",
        streaming: true,
        think: false,
        effort: nil
      })

    html = render(view)
    refute html =~ "pending-row-#{entry.id}"
  end

  ## Model filter as select ------------------------------------------------------

  test "model filter is a select with model aliases", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    assert has_element?(view, "#logs-filter-form select[name='filter[model_search]']")
  end

  ## Date filters and timezone ----------------------------------------------------

  test "date from/to filters respect the user's timezone", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")

    # 1 hora ANTES de la medianoche local (UTC-6) → "ayer" en tiempo local
    today_start = Periods.start_of_day_utc("America/Mexico_City")
    %{owner: owner} = member_with_log(inserted_at: DateTime.add(today_start, -3600, :second))

    # Ancla única: el email del owner solo aparece en la fila del log,
    # NO en los <option> del form (model_requested sí está en el select).
    anchor = owner.email

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/logs")

    # Sin filtro el log aparece
    assert html =~ anchor

    # "desde hoy local": el log de ayer local desaparece
    today = Periods.local_today("America/Mexico_City") |> Date.to_iso8601()

    view
    |> form("#logs-filter-form", filter: %{from: today})
    |> render_change()

    html = render(view)
    refute html =~ anchor

    # "hasta ayer local": el log SÍ aparece (cae en ayer local)
    yesterday = Date.add(Periods.local_today("America/Mexico_City"), -1) |> Date.to_iso8601()

    view
    |> form("#logs-filter-form", filter: %{from: "", to: yesterday})
    |> render_change()

    html = render(view)
    assert html =~ anchor

    # "hasta anteayer local": el log desaparece
    anteayer = Date.add(Periods.local_today("America/Mexico_City"), -2) |> Date.to_iso8601()

    view
    |> form("#logs-filter-form", filter: %{from: "", to: anteayer})
    |> render_change()

    html = render(view)
    refute html =~ anchor
  end

  ## Realtime KPI cards (rolling 5-minute window) ---------------------------------

  test "KPI cards show rolling-window metrics, not lifetime totals", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{log: log} = member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    assert has_element?(view, "#summary-req-per-min")
    assert has_element?(view, "#summary-latency")
    assert has_element?(view, "#summary-errors")
    refute has_element?(view, "#summary-cost")
    refute has_element?(view, "#summary-savings")

    # member_with_log's log was inserted now → inside the window, 42ms latency
    assert has_element?(view, "#summary-latency", "42")
    # 1 request, no errors
    assert has_element?(view, "#summary-errors", "0")
    assert log.latency_ms == 42
  end

  test "KPI cards refresh periodically even without new logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    # Simulate a periodic tick — the view must re-query and stay consistent
    send(view.pid, :refresh_summary)
    html = render(view)
    assert html =~ "summary-req-per-min"
  end

  ## Alerts merged from /dashboard/alerts ----------------------------------------

  test "exhausted member appears in the budget section with period badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {member, member_user, team} = broke_member_fixture()

    # $150 > $100 monthly.
    log_spend(member.id, "150.00")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    assert has_element?(view, "#alert-budget-#{member.id}", member_user.email)
    assert has_element?(view, "#alert-budget-#{member.id}", team.name)
    assert has_element?(view, "#alert-budget-#{member.id}", "mensual")
    assert has_element?(view, "#alert-budget-credits-#{member.id}")
  end

  test "summary card counts members without credit", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {member, _member_user, _team} = broke_member_fixture()

    log_spend(member.id, "100.00")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    assert has_element?(view, "#alert-count-budgets", "1")
  end

  test "member under the limit does not appear in the budget section", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {member, _member_user, _team} = broke_member_fixture()

    log_spend(member.id, "10.00")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/logs")

    refute has_element?(view, "#alert-budget-#{member.id}")
  end

  test "error_reason filter filters logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member} = member_with_log()

    # Log with error
    {:ok, _} =
      Logs.log_request(%{
        team_member_id: member.id,
        model_requested: "err-model",
        model_responded: "err-model",
        status_code: 429,
        error_reason: "rate_limited",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/logs")

    assert html =~ "err-model"

    view
    |> form("#logs-filter-form", filter: %{error_reason: "rate_limited"})
    |> render_change()

    html = render(view)
    assert html =~ "err-model"

    view
    |> form("#logs-filter-form", filter: %{error_reason: "timeout"})
    |> render_change()

    html = render(view)
    refute html =~ "err-model"
  end
end
