defmodule TokengateWeb.LogsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs, Providers}
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
        market_input_price_per_1m: "1.50",
        market_output_price_per_1m: "3.00",
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
        cost_usd: "0.005",
        provider_cost_usd: "0.004",
        savings_usd: "0.001",
        estimated_cost_usd: "0.01",
        latency_ms: 42,
        streaming: false,
        think: Keyword.get(opts, :think, true),
        effort: Keyword.get(opts, :effort, "high"),
        api_key_prefix: "sk-logs-"
      })

    %{team: team, owner: owner, member: member, log: log, model_alias: model_alias}
  end

  setup do
    pid = Process.whereis(Inflight) || start_supervised!(Inflight)
    _ = :sys.get_state(pid)

    for entry <- Inflight.list() do
      Inflight.finish_request(entry.id)
    end

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
        api_key_prefix: "sk-live-"
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
end
