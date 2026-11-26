defmodule TokengateWeb.StatsRouterTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Logs
  alias Tokengate.Providers
  alias Tokengate.Repo
  alias Tokengate.SmartRouter.Config, as: RouterConfig
  alias Tokengate.SmartRouter.ShadowEvaluation

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

  ## Shadow fixtures ----------------------------------------------------------

  # The window of the Router tab is the canonical `today` window, so every
  # evaluation has to sit inside today's UTC day AND before "now": a fixed hour
  # would be in the future during the first hour of the day.
  defp shadow_at do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    start_of_day = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    candidate = DateTime.add(now, -60, :second)

    if DateTime.compare(candidate, start_of_day) == :lt do
      DateTime.add(start_of_day, 1, :second)
    else
      candidate
    end
  end

  defp shadow_config(attrs) do
    attrs = Map.merge(%{name: "Shadow #{unique()}"}, attrs)

    {:ok, config} =
      %RouterConfig{}
      |> RouterConfig.changeset(attrs)
      |> Repo.insert()

    config
  end

  defp shadow_eval(config, attrs) do
    base = %{
      request_log_id: Ecto.UUID.generate(),
      request_inserted_at: shadow_at(),
      shadow_config_id: config.id,
      shadow_config_name: config.name,
      default_use_case_key: "coding_implement",
      default_effort_tier: "medium",
      default_model_name: "model-default",
      use_case_key: "coding_implement",
      effort_tier: "medium",
      model_name: "model-default",
      decision_source: "rule",
      decision_ms: 5,
      matches_default_model: true,
      matches_default_tier: true
    }

    {:ok, eval} =
      %ShadowEvaluation{}
      |> ShadowEvaluation.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    eval
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

  ## Default vs Shadow ---------------------------------------------------------

  test "the Shadow comparison renders agreement, money and the migration breakdown",
       %{conn: conn} do
    shadow = shadow_config(%{name: "Shadow cheap", shadow_enabled: true})

    # Agrees on model and tier, and is cheaper.
    shadow_eval(shadow, %{
      default_served_cost_usd: Decimal.new("1.000000"),
      estimated_served_cost_usd: Decimal.new("0.400000")
    })

    # Full disagreement: medium/high → low, default model → a cheaper one.
    shadow_eval(shadow, %{
      matches_default_model: false,
      matches_default_tier: false,
      default_effort_tier: "medium",
      effort_tier: "low",
      default_model_name: "model-default",
      model_name: "model-cheap",
      default_served_cost_usd: Decimal.new("1.200000"),
      estimated_served_cost_usd: Decimal.new("0.300000")
    })

    conn = admin_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/stats/router")
    wait_router_loaded(view)

    assert has_element?(view, "#router-shadow-comparison")
    assert has_element?(view, "#router-shadow-table")
    assert has_element?(view, "#router-shadow-#{shadow.id}", shadow.name)

    # A version that is currently shadowing carries the live badge.
    assert has_element?(view, "#router-shadow-live-#{shadow.id}")

    # Agreement divides by the ok rows: 1 of 2 models and 1 of 2 tiers.
    assert has_element?(view, "#router-shadow-#{shadow.id}", "50.0%")

    # The migration breakdown names the exact migration, not a summary.
    assert has_element?(view, "#router-shadow-migrations")
    assert has_element?(view, "#router-shadow-migration-table", "model-cheap")
    assert has_element?(view, "#router-shadow-migration-table", "low")

    # 2.20 served vs 0.70 estimated: a real saving, painted green.
    assert has_element?(view, "#router-shadow-#{shadow.id} td.text-success")

    # The version manager lives in /catalog/router.
    assert has_element?(
             view,
             "#router-shadow-open-#{shadow.id}[href*='/catalog/router?tab=versions']"
           )
  end

  test "an estimate above the Default is painted red and an agreeing version shows no migration",
       %{conn: conn} do
    shadow = shadow_config(%{name: "Shadow premium"})

    shadow_eval(shadow, %{
      default_served_cost_usd: Decimal.new("0.200000"),
      estimated_served_cost_usd: Decimal.new("0.500000")
    })

    conn = admin_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/stats/router")
    wait_router_loaded(view)

    assert has_element?(view, "#router-shadow-#{shadow.id} td.text-error")
    assert has_element?(view, "#router-shadow-#{shadow.id}", "$0.3")

    # Not a shadow anymore: no live badge.
    refute has_element?(view, "#router-shadow-live-#{shadow.id}")

    # Every evaluation agreed → there is no migration to show, and the page
    # says so instead of rendering an empty table.
    refute has_element?(view, "#router-shadow-migrations")
    assert has_element?(view, "#router-shadow-agreement")
  end

  test "the version switcher and ?shadow_config_id= choose whose migrations are shown",
       %{conn: conn} do
    busy = shadow_config(%{name: "Shadow busy"})
    quiet = shadow_config(%{name: "Shadow quiet"})

    for _ <- 1..2 do
      shadow_eval(busy, %{
        matches_default_model: false,
        matches_default_tier: false,
        model_name: "busy-model"
      })
    end

    shadow_eval(quiet, %{
      matches_default_model: false,
      matches_default_tier: false,
      model_name: "quiet-model"
    })

    conn = admin_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/stats/router?period=30d")
    wait_router_loaded(view)

    # The busiest version is the default selection.
    assert has_element?(view, "#router-shadow-migration-table", "busy-model")
    refute has_element?(view, "#router-shadow-migration-table", "quiet-model")
    assert has_element?(view, "#router-shadow-select-#{busy.id}.btn-primary")

    # Switching versions patches the URL: the period survives the switch.
    view |> element("#router-shadow-select-#{quiet.id}") |> render_click()
    wait_router_loaded(view)

    assert has_element?(view, "#router-shadow-migration-table", "quiet-model")
    refute has_element?(view, "#router-shadow-migration-table", "busy-model")
    assert has_element?(view, "#router-shadow-select-#{quiet.id}.btn-primary")
    assert has_element?(view, "#period-30d.btn-primary")

    # A shared link opens the same version.
    {:ok, linked, _html} =
      live(recycle(conn), ~p"/stats/router?period=30d&shadow_config_id=#{quiet.id}")

    wait_router_loaded(linked)
    assert has_element?(linked, "#router-shadow-migration-table", "quiet-model")
  end
end
