defmodule TokengateWeb.StatsFinopsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Providers}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "finops-#{u}@example.com",
        name: "Finops #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    {:ok, user} = Accounts.update_user_locale(user, "es")
    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp seed_finops_fixture do
    u = unique()
    %{user: user_a} = register("user")
    %{user: user_b} = register("user")

    {:ok, group} = Accounts.create_group(%{name: "finops-grp-#{u}"})
    {:ok, member_a} = Accounts.create_group_member(%{user_id: user_a.id, group_id: group.id})
    {:ok, member_b} = Accounts.create_group_member(%{user_id: user_b.id, group_id: group.id})

    {:ok, service} = Accounts.create_service(%{name: "finops-svc-#{u}"})

    {:ok, provider} =
      Providers.create_provider(%{
        name: "finops-prov-#{u}",
        base_url: "http://localhost:1"
      })

    {:ok, model_chat} =
      Providers.create_model(%{
        name: "finops-chat-#{u}",
        context_window: 128_000
      })

    {:ok, model_embed} =
      Providers.create_model(%{
        name: "finops-embed-#{u}",
        context_window: 8_192
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # User A: chat with thinking + cache read
    {:ok, _} =
      Logs.log_request(%{
        subject_type: "user",
        user_id: user_a.id,
        group_member_id: member_a.id,
        provider_id: provider.id,
        model_id: model_chat.id,
        model_requested: model_chat.name,
        model_responded: model_chat.name,
        request_type: "chat",
        status_code: 200,
        prompt_tokens: 1000,
        completion_tokens: 500,
        cache_read_tokens: 400,
        think: true,
        effort_applied: "high",
        provider_cost_usd: Decimal.new("1.2000"),
        latency_ms: 800,
        inserted_at: now
      })

    # User B: cheap local cache hit ($0)
    {:ok, _} =
      Logs.log_request(%{
        subject_type: "user",
        user_id: user_b.id,
        group_member_id: member_b.id,
        provider_id: provider.id,
        model_id: model_chat.id,
        model_requested: model_chat.name,
        request_type: "chat",
        status_code: 200,
        cache_hit: true,
        prompt_tokens: 0,
        completion_tokens: 0,
        provider_cost_usd: Decimal.new("0"),
        latency_ms: 0,
        inserted_at: now
      })

    # Service: embeddings + 1 failed chat error
    {:ok, _} =
      Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        provider_id: provider.id,
        model_id: model_embed.id,
        model_requested: model_embed.name,
        request_type: "embeddings",
        status_code: 200,
        prompt_tokens: 2000,
        completion_tokens: 0,
        provider_cost_usd: Decimal.new("0.0500"),
        latency_ms: 60,
        inserted_at: now
      })

    {:ok, _} =
      Logs.log_request(%{
        subject_type: "service",
        service_id: service.id,
        provider_id: provider.id,
        model_id: model_chat.id,
        model_requested: model_chat.name,
        request_type: "chat",
        status_code: 502,
        prompt_tokens: 300,
        completion_tokens: 50,
        provider_cost_usd: Decimal.new("0.1500"),
        latency_ms: 150,
        inserted_at: now
      })

    %{user_a: user_a, user_b: user_b, service: service, group: group, model_chat: model_chat}
  end

  test "non-admin cannot access /stats/finops", %{conn: conn} do
    %{user: plain, password: password} = register("user")
    conn = login(conn, plain, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/stats/finops")
  end

  test "FinOps separa Usuarios vs Servicios, anatomía, capacidades, scatter y toggles", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")

    %{user_a: user_a, user_b: user_b, service: service, model_chat: model} =
      seed_finops_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/finops?period=week")
    _ = render_async(view)

    assert has_element?(view, "#nav-finops.btn-primary")
    assert has_element?(view, "#finops-stats")
    assert has_element?(view, "#csv-finops")

    # Twin scorecards & proportion bars
    assert has_element?(view, "#finops-proportion-spend")
    assert has_element?(view, "#finops-proportion-requests")
    assert has_element?(view, "#finops-users-card", "$1.2000")
    assert has_element?(view, "#finops-services-card", "$0.2000")

    # Trend chart & metric toggles
    assert has_element?(view, "#finops-trend-chart")
    assert has_element?(view, "#finops-trend-chart-metric-toggle")

    view
    |> element("#finops-trend-chart-metric-toggle button[phx-value-metric='cpr']")
    |> render_click()

    assert has_element?(
             view,
             "#finops-trend-chart-metric-toggle button.btn-primary[phx-value-metric='cpr']"
           )

    # Spend & waste anatomy + local cache + capability breakdown
    assert has_element?(view, "#finops-anatomy-bar")
    assert has_element?(view, "#finops-anatomy-pill-local", "1")
    assert has_element?(view, "#finops-capabilities-chat")
    assert has_element?(view, "#finops-capabilities-embeddings")

    # Scatter plot Y toggle (cpr -> cache) & Top 5 Users/Services tables
    assert has_element?(view, "#finops-scatter-plot")

    # Cruz centrada en el área dibujada, esquina sombreada anclada al centro y
    # marquitas en los ejes para la mediana de cada grupo (sin líneas cruzando).
    assert has_element?(view, "#finops-scatter-cross-x")
    assert has_element?(view, "#finops-scatter-cross-y")
    assert has_element?(view, "#finops-scatter-quadrant")
    assert has_element?(view, "#finops-scatter-tick-x-user")
    assert has_element?(view, "#finops-scatter-tick-y-user")
    assert has_element?(view, "#finops-scatter-tick-x-service")
    assert has_element?(view, "#finops-scatter-tick-y-service")
    assert has_element?(view, "#finops-scatter-cheapest-empty")

    # La letra chica va a la vista: qué mide cada cosa y qué no. La fórmula es
    # literal (no pasa por gettext), así que sirve de ancla estable.
    assert has_element?(view, "#finops-glossary")
    assert has_element?(view, "#finops-glossary", "median of X and Y, per group")
    assert has_element?(view, "#finops-glossary", "SUM(provider_cost_usd)")
    assert has_element?(view, "#finops-legend")

    html = render(view)
    {glossary_pos, _} = :binary.match(html, ~s(id="finops-glossary"))
    {legend_pos, _} = :binary.match(html, ~s(id="finops-legend"))
    assert legend_pos > glossary_pos
    # El sujeto 100% caché local ($0) no desaparece: baja a la tira de no
    # facturables con sus requests ahorradas.
    assert has_element?(view, "#finops-scatter-cache-only")

    # Mapa de modelos/proveedores: mismo componente, con su propio toggle de
    # entidad y el eje de razonamiento (costo unitario ↔ % de thinking tax).
    assert has_element?(view, "#finops-entity-scatter-plot")
    assert has_element?(view, "#finops-entity-scatter-entity-toggle")
    assert has_element?(view, "#finops-entity-scatter-metric-toggle")

    view
    |> element("#finops-entity-scatter-entity-toggle button[phx-value-entity='providers']")
    |> render_click()

    assert has_element?(
             view,
             "#finops-entity-scatter-entity-toggle button.btn-primary[phx-value-entity='providers']"
           )

    view
    |> element("#finops-entity-scatter-metric-toggle button[phx-value-metric='think']")
    |> render_click()

    assert has_element?(
             view,
             "#finops-entity-scatter-metric-toggle button.btn-primary[phx-value-metric='think']"
           )

    # El eje de razonamiento se rotula en %, no en dólares.
    assert has_element?(view, "#finops-entity-scatter-plot text", "100%")
    refute has_element?(view, "#finops-entity-scatter-plot text", "$100")

    # Filtros: la URL manda. Al filtrar por modelo/uso, la página se recarga
    # sólo con ese recorte y el chip lo declara.
    view
    |> element("#finops-filter-form")
    |> render_change(%{"model_id" => model.id})

    assert_patch(view, ~p"/stats/finops?period=week&model_id=#{model.id}")
    _ = render_async(view)

    # El selector de período tiene que conservar el filtro y seguir siendo una
    # URL válida: antes armaba `/stats/finops&model_id=…?period=…` (404).
    assert has_element?(
             view,
             "#period-today[href='/stats/finops?period=today&model_id=#{model.id}']"
           )

    assert has_element?(view, "#finops-filter-active")
    assert has_element?(view, "#finops-chip-model", model.name)
    assert has_element?(view, "#finops-filter-clear")

    # Reconciliación explícita: servido ≠ real cuando hubo clasificador.
    assert has_element?(view, "#finops-real-spend", "router")

    # Sin filtros: la página vuelve al agregado del período.
    view |> element("#finops-filter-clear") |> render_click()
    assert_patch(view, ~p"/stats/finops?period=week")

    view
    |> element("#finops-scatter-metric-toggle button[phx-value-metric='cache']")
    |> render_click()

    assert has_element?(
             view,
             "#finops-scatter-metric-toggle button.btn-primary[phx-value-metric='cache']"
           )

    assert has_element?(view, "#finops-top-users", user_a.email)
    assert has_element?(view, "#finops-top-users", user_b.email)
    assert has_element?(view, "#finops-top-services", service.name)

    # Period selector stays on /stats/finops (does not jump to /stats/overview)
    view
    |> element("#period-30d")
    |> render_click()

    assert_patch(view, ~p"/stats/finops?period=30d")
  end

  test "listado Users mantiene Share del periodo real al filtrar por búsqueda", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user_a: user_a, user_b: user_b} = seed_finops_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/users?period=week")
    _ = render_async(view)

    assert has_element?(view, "#user-table")
    assert has_element?(view, "#bd-user-#{user_a.id}")
    assert has_element?(view, "#bd-user-#{user_b.id}")

    # Filter to user_b ($0.00 cost out of $1.2000 total) — Share must remain 0%, not 100%
    view
    |> element("#user-list-search-form")
    |> render_change(%{"value" => user_b.email})

    assert has_element?(view, "#bd-user-#{user_b.id}")
    refute has_element?(view, "#bd-user-#{user_a.id}")
    assert has_element?(view, "#bd-user-#{user_b.id}", "0%")
  end
end
