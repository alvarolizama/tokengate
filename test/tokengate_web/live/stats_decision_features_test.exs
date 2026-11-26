defmodule TokengateWeb.StatsDecisionFeaturesTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Providers}
  alias Tokengate.Metrics.Rollup

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "decision-#{u}@example.com",
        name: "Decision #{u}",
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

  defp seed_fixture do
    u = unique()
    %{user: owner} = register("user")

    {:ok, group} = Accounts.create_group(%{name: "grp-#{u}"})
    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, service} = Accounts.create_service(%{name: "svc-#{u}"})

    {:ok, provider} =
      Providers.create_provider(%{
        name: "prov-#{u}",
        base_url: "http://localhost:1"
      })

    {:ok, model_expensive} =
      Providers.create_model(%{
        name: "claude-opus-test-#{u}",
        context_window: 200_000,
        market_input_price_per_1m: Decimal.new("15.00"),
        market_output_price_per_1m: Decimal.new("75.00")
      })

    {:ok, model_cheap} =
      Providers.create_model(%{
        name: "gpt-mini-test-#{u}",
        context_window: 128_000,
        market_input_price_per_1m: Decimal.new("0.15"),
        market_output_price_per_1m: Decimal.new("0.60")
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # 1 expensive Claude Code log with reasoning effort + cache
    {:ok, _} =
      Logs.log_request(%{
        subject_type: "user",
        user_id: owner.id,
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: model_expensive.id,
        model_requested: model_expensive.name,
        model_responded: model_expensive.name,
        agent_type: "claude-code",
        client_agent: "claude-code/2.1.0",
        status_code: 200,
        prompt_tokens: 1000,
        completion_tokens: 500,
        cache_read_tokens: 400,
        effort_applied: "high",
        think: true,
        provider_cost_usd: Decimal.new("1.2500"),
        latency_ms: 850,
        streaming: true,
        inserted_at: now
      })

    # 2 cheap service error logs on cheap model
    for idx <- 1..2 do
      {:ok, _} =
        Logs.log_request(%{
          subject_type: "service",
          service_id: service.id,
          provider_id: provider.id,
          model_id: model_cheap.id,
          model_requested: model_cheap.name,
          model_responded: model_cheap.name,
          agent_type: "api",
          client_agent: "python-sdk/1.0",
          status_code: if(idx == 1, do: 502, else: 200),
          prompt_tokens: 200,
          completion_tokens: 50,
          provider_cost_usd: Decimal.new("0.0100"),
          latency_ms: 120,
          streaming: false,
          inserted_at: now
        })
    end

    %{
      owner: owner,
      group: group,
      member: member,
      service: service,
      provider: provider,
      model_expensive: model_expensive,
      model_cheap: model_cheap
    }
  end

  defp wait_stats_loaded(view) do
    _ = render_async(view)
    view
  end

  test "En vivo muestra qué cuesta en los últimos 15 min, ritmo vs ayer y toggle de gráfica", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    %{model_expensive: model_exp, service: service} = seed_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats")

    assert has_element?(view, "#live-cost-drivers")
    assert has_element?(view, "#live-drivers-models", model_exp.name)
    assert has_element?(view, "#live-drivers-consumers", service.name)
    assert has_element?(view, "#live-drivers-agents", "Claude Code")

    # Toggle de métrica en la gráfica por hora (Requests -> Cost)
    assert has_element?(view, "#live-day-hour-chart-metric-toggle")

    view
    |> element("#live-day-hour-chart-metric-toggle button[phx-value-metric='cost']")
    |> render_click()

    assert has_element?(
             view,
             "#live-day-hour-chart-metric-toggle button.btn-primary[phx-value-metric='cost']"
           )
  end

  test "Overview muestra tendencia diaria (week), eficiencia/desperdicio, consumidores, agentes y toggle costo/requests",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{model_expensive: model_exp, owner: owner, service: service} = seed_fixture()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/stats/overview?period=week")
    view = wait_stats_loaded(view)

    assert has_element?(view, "#overview-daily-chart")
    assert has_element?(view, "#overview-efficiency")
    assert has_element?(view, "#overview-efficiency", "$0.01")
    assert has_element?(view, "#overview-top-consumers", owner.name)
    assert has_element?(view, "#overview-top-consumers", service.name)
    assert has_element?(view, "#overview-top-agents", "Claude Code")

    # Por defecto ordena By cost → model_expensive ($1.25, 1 req) va primero que model_cheap ($0.02, 2 reqs)
    assert has_element?(view, "#model-breakdown-row-1", model_exp.name)

    # Cambiar a By requests pone al modelo barato (2 reqs) primero
    view
    |> element("#overview-metric-toggle button[phx-value-metric='requests']")
    |> render_click()

    refute has_element?(view, "#model-breakdown-row-1", model_exp.name)
  end

  test "Drill-down de agente (/stats/agents/:key) y enlaces desde modelo, proveedor y usuario", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")

    %{model_expensive: model_exp, provider: provider, owner: owner, service: service} =
      seed_fixture()

    conn = login(conn, admin, password)

    # 1. Agent detail page (clicking from /stats/agents or navigating via canonical key)
    agent_key = Tokengate.Agents.identify("claude-code/2.1.0", "claude-code").key
    {:ok, agent_view, _html} = live(conn, ~p"/stats/agents/#{agent_key}?period=week")
    agent_view = wait_stats_loaded(agent_view)

    assert has_element?(agent_view, "#agent-detail-header", "Claude Code")
    assert has_element?(agent_view, "#agent-kpi-cost", "$1.25")
    assert has_element?(agent_view, "#agent-effort-breakdown", "high")
    assert has_element?(agent_view, "#agent-models", model_exp.name)
    assert has_element?(agent_view, "#agent-consumers", owner.name)

    # 2. Model detail muestra servicios y agentes + precios de mercado
    {:ok, model_view, _html} = live(conn, ~p"/stats/models/#{model_exp.id}?period=week")
    model_view = wait_stats_loaded(model_view)

    assert has_element?(model_view, "#model-kpi-cost", "$15")
    assert has_element?(model_view, "#model-agents-card", "Claude Code")

    # 3. Provider detail muestra gráfica diaria por modelo
    {:ok, prov_view, _html} = live(conn, ~p"/stats/providers/#{provider.id}?period=week")
    prov_view = wait_stats_loaded(prov_view)

    assert has_element?(prov_view, "#provider-daily-chart")
    assert has_element?(prov_view, "#provider-services", service.name)

    # 4. User detail muestra agentes usados y proveedores usados
    {:ok, user_view, _html} = live(conn, ~p"/stats/users/#{owner.id}?period=week")
    html = render_async(user_view)

    assert html =~ "user-agents-breakdown"
    assert html =~ "Claude Code"
    assert html =~ "user-providers-breakdown"
    assert html =~ provider.name
  end

  test "Rollup.efficiency_summary y Logs.live_cost_drivers agregan costo y errores con precisión" do
    %{model_expensive: model_exp, service: service} = seed_fixture()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from = DateTime.add(now, -3600, :second)
    to = DateTime.add(now, 60, :second)

    eff = Rollup.efficiency_summary(from: from, to: to)
    assert eff.total_requests == 3
    assert eff.error_requests == 1
    assert Decimal.equal?(eff.error_cost_usd, Decimal.new("0.0100"))
    assert eff.think_requests == 1
    assert Decimal.equal?(eff.think_cost_usd, Decimal.new("1.2500"))
    assert eff.service_requests == 2

    drivers = Logs.live_cost_drivers(15, 5)
    assert hd(drivers.top_models).model_id == model_exp.id
    assert Enum.any?(drivers.top_consumers, &(&1.subject_id == service.id))
    assert Enum.any?(drivers.top_agents, &(&1.label == "Claude Code"))
  end
end
