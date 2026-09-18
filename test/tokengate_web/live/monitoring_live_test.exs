defmodule TokengateWeb.MonitoringLiveTest do
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

    # Este archivo afirma textos en español del LiveView; el idioma por defecto
    # de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp member_with_log(opts \\ []) do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Logs Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "logs-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, model} =
      Providers.create_model(%{
        name: "model-#{u}",
        context_window: 128_000
      })

    {:ok, log} =
      Logs.log_request(%{
        group_member_id: member.id,
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

    %{group: group, owner: owner, member: member, log: log, model: model}
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
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/operations/monitoring")
  end

  ## User / group / think / effort columns ---------------------------------------

  test "shows user, group, think and effort for completed logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{group: group, owner: owner} = member_with_log(think: true, effort: "high")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

    html = render(view)
    assert html =~ owner.email
    assert html =~ group.name
    assert html =~ "high"
  end

  ## Pending (in-flight) rows ---------------------------------------------------

  test "pending request appears live and disappears when done", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member} = member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

    entry =
      Inflight.start_request(%{
        group_member_id: member.id,
        user_email: "live@example.com",
        group_name: "Live Group",
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
    assert html =~ "pending-#{entry.id}"
    assert html =~ "En vuelo"
    assert html =~ "live@example.com"

    Inflight.finish_request(entry.id)
    html = render(view)
    refute html =~ "pending-#{entry.id}"
  end

  test "pending respects model filter", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member, model: model} = member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

    # Filtrar por el modelo del test: el pending usa otro modelo y debe ocultarse
    view
    |> form("#logs-filter-form", filter: %{model_search: model.name})
    |> render_change()

    entry =
      Inflight.start_request(%{
        group_member_id: member.id,
        model_requested: "glm-5.2",
        streaming: true,
        think: false,
        effort: nil
      })

    html = render(view)
    refute html =~ "pending-row-#{entry.id}"
  end

  ## Model filter as select ------------------------------------------------------

  test "model filter is a select with models", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

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
    {:ok, view, html} = live(conn, ~p"/operations/monitoring")

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
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

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
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

    # Simulate a periodic tick — the view must re-query and stay consistent
    send(view.pid, :refresh_summary)
    html = render(view)
    assert html =~ "summary-req-per-min"
  end

  ## Alerts --------------------------------------------------------------------

  test "error_reason filter filters logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{member: member} = member_with_log()

    # Log with error
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_requested: "err-model",
        model_responded: "err-model",
        status_code: 429,
        error_reason: "rate_limited",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/operations/monitoring")

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

  ## API key filter ------------------------------------------------------------

  defp api_key_for(owner, member, suffix) do
    u = unique()

    {:ok, key} =
      Accounts.create_api_key(%{
        subject_type: "member",
        user_id: owner.id,
        group_member_id: member.id,
        label: "Clave #{suffix} #{u}",
        key_hash: "hash-#{suffix}-#{u}",
        key_prefix: "sk-#{suffix}-#{u}-"
      })

    key
  end

  defp log_for_key(member, key, model_name) do
    {:ok, log} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_requested: model_name,
        model_responded: model_name,
        status_code: 200,
        api_key_id: key.id,
        api_key_prefix: key.key_prefix,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    log
  end

  test "filtering by an api key returns only that key's logs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{owner: owner, member: member} = member_with_log()
    u = unique()

    key_a = api_key_for(owner, member, "a")
    key_b = api_key_for(owner, member, "b")

    _log_a = log_for_key(member, key_a, "key-a-model-#{u}")
    log_b = log_for_key(member, key_b, "key-b-model-#{u}")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

    # Ambas keys aparecen en el selector con su label
    assert has_element?(view, "#logs-filter-form select[name='filter[api_key_id]']")

    assert has_element?(
             view,
             "#logs-filter-form select[name='filter[api_key_id]'] option",
             key_a.label
           )

    # La columna "API Key" muestra el label de la key viva, no el prefijo
    assert has_element?(view, "#logs td", key_a.label)
    assert has_element?(view, "#logs td", key_b.label)
    refute has_element?(view, "#logs td", key_a.key_prefix)

    view
    |> form("#logs-filter-form", filter: %{api_key_id: key_a.id})
    |> render_change()

    html = render(view)
    assert html =~ "key-a-model-#{u}"
    refute html =~ "key-b-model-#{u}"
    assert has_element?(view, "#logs td", key_a.label)
    refute has_element?(view, "#logs td", key_b.label)
    assert log_b.id
  end

  test "api key column falls back to the historical prefix without a live key", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{owner: owner} = member_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/monitoring")

    assert has_element?(view, "#logs td", owner.email)
    # Sin key viva, la celda cae al prefijo histórico
    assert has_element?(view, "#logs td", "sk-logs-")
  end

  ## System monitor section -------------------------------------------------

  test "non-admin is redirected away from the logs dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)

    # The whole /logs lives behind live_session :admin, so a plain
    # user never even mounts the view — they get bounced to /dashboard.
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/operations/monitoring")
  end
end
