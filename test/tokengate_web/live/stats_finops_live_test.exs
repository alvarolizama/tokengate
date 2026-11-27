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

    %{user_a: user_a, user_b: user_b, service: service, group: group}
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
    %{user_a: user_a, user_b: user_b, service: service} = seed_finops_fixture()

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

    # Cuadrante: una guía por grupo (Users y Services) con su mediana, y con
    # muestra mínima de 10 requests facturables ningún sujeto del fixture
    # califica todavía: el aviso lo dice en vez de coronar a nadie.
    assert has_element?(view, "#finops-scatter-quadrant-guides")
    assert has_element?(view, "#finops-scatter-quadrant-user")
    assert has_element?(view, "#finops-scatter-quadrant-service")
    assert has_element?(view, "#finops-scatter-efficient-empty")
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
