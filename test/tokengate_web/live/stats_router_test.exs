defmodule TokengateWeb.StatsRouterTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Providers

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "stats-router-#{u}@example.com",
        name: "Stats Router #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma textos en español; el idioma por defecto de la UI es
    # inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp admin_conn(conn) do
    %{user: user, password: password} = register("admin")
    login(conn, user, password)
  end

  # The Router tab loads its bundle in an async task; `:sys.get_state/1` syncs
  # with the LiveView process (it drains pending messages first).
  defp wait_router_loaded(view, attempts \\ 400)

  defp wait_router_loaded(view, attempts) when attempts > 0 do
    assigns = :sys.get_state(view.pid).socket.assigns

    if assigns[:stats_loading] == false and assigns[:router_summary] != nil do
      view
    else
      Process.sleep(10)
      wait_router_loaded(view, attempts - 1)
    end
  end

  defp wait_router_loaded(_view, 0), do: raise("router stats never loaded")

  defp subject_fixture do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Router Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "router-owner-#{u}@example.com",
        name: "Router Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} = Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, provider} =
      Providers.create_provider(%{name: "Router Prov #{u}", base_url: "http://localhost:1"})

    {:ok, model} = Providers.create_model(%{name: "router-model-#{u}", context_window: 128_000})

    %{
      group: group,
      owner: owner,
      member: member,
      provider: provider,
      model: model,
      name: model.name
    }
  end

  defp base_log_attrs(ctx) do
    %{
      group_member_id: ctx.member.id,
      user_id: ctx.owner.id,
      provider_id: ctx.provider.id,
      model_id: ctx.model.id,
      model_requested: ctx.model.name,
      model_resolved: ctx.model.name,
      agent_type: "api",
      status_code: 200,
      prompt_tokens: 1_000,
      completion_tokens: 500,
      provider_cost_usd: "0.020",
      latency_ms: 1_000,
      ttft_ms: 200,
      streaming: false,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp routed_log(ctx) do
    {:ok, log} =
      Logs.log_request(
        Map.merge(base_log_attrs(ctx), %{
          routed_via_router: true,
          router_use_case_key: "coding_implement",
          router_effort_tier: "high",
          router_decision_source: "classifier",
          router_decision_ms: 120,
          router_decision_cost_usd: "0.010",
          router_baseline_cost_usd: "0.010",
          router_direct_access: false,
          prompt_tokens_saved_est: 50,
          session_id: "sess-#{unique()}"
        })
      )

    log
  end

  defp direct_log(ctx) do
    {:ok, log} =
      Logs.log_request(
        Map.merge(base_log_attrs(ctx), %{
          routed_via_router: false,
          provider_cost_usd: "0.010"
        })
      )

    log
  end

  ## Navigation --------------------------------------------------------------

  test "the Router tab lives inside #stats-nav and loads", %{conn: conn} do
    conn = admin_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/stats/router")
    wait_router_loaded(view)

    assert has_element?(view, "#stats-nav #nav-router")
    assert has_element?(view, "#nav-router.btn-primary")
    assert has_element?(view, "#period-selector")
    assert has_element?(view, "#router-stats")
    assert has_element?(view, "#router-kpis")
    # Sin tráfico enrutado, los KPI existen y valen cero: la página no finge
    # datos que no midió.
    assert has_element?(view, "#router-kpi-requests", "0")
    assert has_element?(view, "#router-attribution")
  end

  test "the Router tab is reachable from another tab", %{conn: conn} do
    conn = admin_conn(conn)

    {:ok, view, _html} = live(conn, ~p"/stats/overview")
    assert has_element?(view, "#nav-router[href*='/stats/router']")

    {:ok, view, _html} = live(recycle(conn), ~p"/stats/router?period=30d")
    wait_router_loaded(view)

    assert has_element?(view, "#nav-router.btn-primary")
    assert has_element?(view, "#period-30d")
  end

  ## Business metrics --------------------------------------------------------

  test "routed traffic renders honest KPIs, the mix, the models and attribution",
       %{conn: conn} do
    ctx = subject_fixture()
    routed_log(ctx)
    direct_log(ctx)

    conn = admin_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/stats/router")
    wait_router_loaded(view)

    assert has_element?(view, "#router-kpi-requests", "1")
    assert has_element?(view, "#router-kpi-coverage", "100.0")
    # Served spend sits next to the ROI KPIs: the model's own cost, before the
    # decision step (0.02 served vs 0.01 classifier).
    assert has_element?(view, "#router-kpi-served", "$0.02")

    # Served 0.02 + decision 0.01 against a 0.01 baseline: the net saving is
    # negative and is painted red instead of being clipped at zero.
    assert has_element?(view, "#router-kpi-net-savings.text-error")

    # Prompt tokens trimmed by the use case knobs.
    assert has_element?(view, "#router-prompt-tokens-saved", "50")

    # Use case × effort mix.
    assert has_element?(view, "#router-use-case-table")
    assert has_element?(view, "#router-uc-coding_implement-high")
    assert render(view) =~ "coding_implement"

    # Model performance, measured on routed traffic only.
    assert has_element?(view, "#router-model-table")
    assert render(view) =~ ctx.name

    # Router vs direct: the same subject has both halves in the window.
    assert has_element?(view, "#router-vs-direct-table")

    # Decision sources.
    assert has_element?(view, "#router-sources-table")
    assert render(view) =~ "classifier"

    # The false-savings traffic light and the insights are always rendered.
    assert has_element?(view, "#router-signals")
    assert has_element?(view, "#router-signal-session_switches")
    assert has_element?(view, "#router-insights")
    assert has_element?(view, "#router-insight-negative_net_savings")

    # «Quién gastó en qué» flags the model the subject could not reach directly.
    # The row id is positional, so duplicate model_id/subject_id pairs can never
    # collide in the DOM.
    assert has_element?(view, "#router-attribution-table")
    assert has_element?(view, "#router-no-direct-0")
  end

  test "classifier-billed router_decision rows never inflate the served traffic",
       %{conn: conn} do
    ctx = subject_fixture()
    routed_log(ctx)

    # The classifier's own billed call: routed, real spend, NOT a served
    # request. It must not add a second row to any breakdown.
    {:ok, _decision} =
      Logs.log_request(
        Map.merge(base_log_attrs(ctx), %{
          routed_via_router: true,
          request_type: "router_decision",
          router_decision_source: "classifier",
          router_decision_ms: 90,
          router_decision_cost_usd: "0.010",
          provider_cost_usd: "0.010"
        })
      )

    conn = admin_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/stats/router")
    wait_router_loaded(view)

    assert has_element?(view, "#router-kpi-requests", "1")

    # One served model → exactly one positional row, no duplicate DOM ids.
    assert has_element?(view, "#router-model-0")
    refute has_element?(view, "#router-model-1")
  end
end
