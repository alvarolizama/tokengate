defmodule TokengateWeb.DashboardLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Logs, Periods, Providers}
  alias Tokengate.Metrics.Collector

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "live-#{u}@example.com",
        name: "Live #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma los textos en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  # Builds org + group + member (+ api key) and returns the ids; optionally
  # inserts a request log for the member with the given cost.
  defp group_with_log(opts) do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})

    owner =
      case Map.get(opts, :user) do
        nil ->
          {:ok, user} =
            Accounts.register_user(%{
              email: "owner-#{u}@example.com",
              name: "Owner #{u}",
              password: "password-secret-#{u}1"
            })

          user

        %{} = user ->
          user
      end

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    provider =
      if Map.get(opts, :cost) do
        {:ok, provider} =
          Providers.create_provider(%{
            name: "P #{u}",
            base_url: "http://localhost:1"
          })

        inserted_at =
          Map.get(opts, :inserted_at) || DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok, _log} =
          Logs.log_request(%{
            group_member_id: member.id,
            provider_id: provider.id,
            model_id: nil,
            model_requested: "gpt-4o",
            model_responded: "gpt-4o",
            agent_type: "claude-code",
            status_code: 200,
            prompt_tokens: 100,
            completion_tokens: 50,
            provider_cost_usd: opts.cost,
            latency_ms: 42,
            streaming: false,
            inserted_at: inserted_at
          })

        provider
      end

    password =
      case Map.get(opts, :user) do
        nil -> "password-secret-#{u}1"
        _ -> nil
      end

    %{group: group, owner: owner, member: member, provider: provider, owner_password: password}
  end

  defp group_with_member(_opts \\ %{}) do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    # Igual que `register/1`: este archivo afirma textos en español y el idioma
    # por defecto de la UI es inglés.
    {:ok, owner} = Accounts.update_user_locale(owner, "es")

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, _api_key, token} = Accounts.replace_api_key(member)

    %{
      group: group,
      owner: owner,
      member: member,
      owner_password: "password-secret-#{u}1",
      token: token
    }
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard")
  end

  test "mount paints the metrics skeleton before the async bundle lands", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)

    # The DEAD render is the shape of the first paint: mount no longer computes
    # the bundle (it is started from handle_params and lands in handle_async),
    # so the static HTML carries the skeleton, not data.
    html = conn |> get(~p"/dashboard") |> html_response(200)

    assert html =~ "metrics-skeleton"
    refute html =~ "kpi-requests"
  end

  test "admin sees the dashboard shell and empty state with no traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Mount is async: the bundle arrives through handle_async/3.
    html = render_async(view)

    assert html =~ "Dashboard"
    assert has_element?(view, "#empty-state")
    assert html =~ "Aún no hay requests"
    refute has_element?(view, "#metrics-skeleton")
  end

  test "admin sees the canonical period selector with all options", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#period-selector")
    assert has_element?(view, "#period-today")
    assert has_element?(view, "#period-yesterday")
    assert has_element?(view, "#period-week.btn-primary")
    assert has_element?(view, "#period-30d")

    # The retired windows are gone from the selector (and from the vocabulary):
    # the href proves the period travels in the URL.
    refute has_element?(view, "#period-7d")
    refute has_element?(view, "#period-last_month")
    assert has_element?(view, "#period-30d[href='/dashboard?period=30d']")
  end

  test "an out-of-set bookmark degrades to the default period", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)

    for bogus <- ["month", "last_month", "7d", "basura"] do
      {:ok, view, _html} = live(recycle(conn), ~p"/dashboard?period=#{bogus}")

      # `normalize_period/2` maps anything outside the canonical set to
      # `Periods.default_period/0` ("week") instead of raising or reading it as
      # another window.
      assert has_element?(view, "#period-week.btn-primary")

      render_async(view)
    end
  end

  test "the URL carries the active period on a direct visit", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard?period=30d")

    assert has_element?(view, "#period-30d.btn-primary")
    html = render_async(view)
    assert html =~ "Costo por día (30d)"
  end

  test "admin sees metric cards when there is traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Insert a log for the ADMIN's own membership (user-wide scope)
    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_async(view)

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#kpi-requests")
    assert has_element?(view, "#kpi-cost")
    assert has_element?(view, "#kpi-tokens")
    assert has_element?(view, "#kpi-tps")
    _ = html
  end

  test "KPI cards show deltas vs the previous period", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # The delta compares the ACTIVE window with the one right before it. Anchor
    # the fixtures on the canonical bounds instead of "now minus N hours": a
    # fixed 8-day offset falls OUTSIDE the previous week when the test runs on
    # a Monday, and the delta would silently have nothing to compare against.
    current = Periods.period_bounds("week", "Etc/UTC")
    previous = Periods.previous_period_bounds("week", "Etc/UTC")

    fixture =
      group_with_log(%{
        cost: "0.005",
        user: admin,
        inserted_at: current.from
      })

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: fixture.member.id,
        provider_id: fixture.provider.id,
        model_id: nil,
        model_requested: "gpt-4o",
        model_responded: "gpt-4o",
        agent_type: "claude-code",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: Decimal.new("0.004"),
        latency_ms: 42,
        streaming: false,
        inserted_at: DateTime.add(previous.from, 3600, :second)
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_async(view)

    assert has_element?(view, "#kpi-cost")
    # Both windows have traffic → a delta arrow + % is rendered.
    assert html =~ "↑" or html =~ "↓"
    assert html =~ "%"
  end

  test "admin does NOT see other members' traffic (user-wide)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Log belongs to ANOTHER user's membership — admin must NOT see it
    group_with_log(%{cost: "0.005"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_async(view)

    assert has_element?(view, "#empty-state")
    assert html =~ "Aún no hay requests"
  end

  test "admin with no memberships sees empty state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)
    assert has_element?(view, "#empty-state")
  end

  test "scope label is Personal for admin (user-wide dashboard)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Personal"
  end

  test "admin sees breakdown tabs", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    assert has_element?(view, "#breakdown-tabs")
    assert has_element?(view, "#tab-model")
    assert has_element?(view, "#tab-member")
    # Group breakdown is not shown on the personal dashboard
    refute has_element?(view, "#tab-group")
  end

  test "the metrics bundle is cached per window and shared by its viewers", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    # The entry is keyed by WINDOW + SCOPE, not by the socket: it is readable
    # before a second viewer exists and never by a different scope.
    assert {:ok, bundle} =
             Tokengate.Metrics.DashboardCache.fetch(
               {:dashboard_bundle, "week", "Etc/UTC", [admin.id]}
             )

    assert bundle.metrics.requests_total == 1

    # A second dashboard of the same scope renders from that entry WITHOUT
    # waiting on an async task (the assertion is in the mount reply).
    {:ok, second, _html} = live(login(build_conn(), admin, password), ~p"/dashboard")

    assert has_element?(second, "#kpi-requests")
  end

  test "switching breakdown tab shows the right table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    fixture = group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    # Default is model. El cuerpo de la tabla (.table) es el ancla del contrato
    # y cada fila conserva su id estable de siempre.
    assert has_element?(view, "#bd-model-rows")
    assert has_element?(view, "#bd-model-rows #bd-model-unknown")

    # Switch to member
    view |> element("#tab-member") |> render_click()
    assert has_element?(view, "#bd-member-rows")
    assert has_element?(view, "#bd-member-rows #bd-member-#{fixture.member.id}")

    # Group tab is not rendered on the personal dashboard
    refute has_element?(view, "#tab-group")
  end

  test "switching period reloads metrics", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Default period is the canonical default (week) — chart title reflects it.
    html = render_async(view)
    assert html =~ "Costo por hora (semana)"

    # Switch to 30d: the patch replies instantly with the previous bundle
    # (dimmed) plus the header spinner; the new bundle lands async.
    html = view |> element("#period-30d") |> render_click()

    # Assert on the click's OWN reply: it is the render right after the
    # handler, so the spinner is guaranteed to still be armed there. A later
    # `has_element?/2` renders again and can race the async task, which may
    # have already cleared the flag.
    assert html =~ ~s(id="dashboard-loading")
    assert html =~ "opacity-60"

    # `render_async` waits for the bundle itself, so the loaded state below is
    # deterministic (no clock, no sleep).
    html = render_async(view)
    assert html =~ "Costo por día (30d)"
    refute has_element?(view, "#dashboard-loading")
    refute html =~ "opacity-60"
  end

  test "period switch keeps stale data visible while loading", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_async(view)
    assert html =~ "Costo por hora (semana)"

    # Mid-flight switch: the previous bundle stays on screen (dimmed), and the
    # titles still describe the displayed (week) period.
    html = view |> element("#period-30d") |> render_click()
    assert html =~ "opacity-60"
    assert html =~ "Costo por hora (semana)"

    # Once the async bundle lands, titles switch and the dim goes away.
    html = render_async(view)
    assert html =~ "Costo por día (30d)"
    refute html =~ "opacity-60"
  end

  test "today period excludes logs from the previous UTC day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    Collector.reset()

    # 23:00 del día UTC anterior → NO cuenta en "Hoy", que mide el día UTC
    # (la ventana del kill-switch), no el día local del usuario.
    utc_start = Periods.start_of_day_utc("Etc/UTC")

    group_with_log(%{
      cost: "0.005",
      user: admin,
      inserted_at: DateTime.add(utc_start, -3600, :second)
    })

    conn = login(conn, admin, password)
    # "Hoy" is an explicit window now (the default is the week): the bookmark
    # carries it, which is also what the selector patches.
    {:ok, view, _html} = live(conn, ~p"/dashboard?period=today")

    render_async(view)
    assert has_element?(view, "#empty-state")
  end

  test "dashboard: el KPI de costo muestra solo el gasto del período", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    # El dashboard es la vista del usuario: el costo va uniforme con el resto
    # de la fila (gasto del período), sin la etiqueta UTC ni el contador del
    # tope global — esa ventana vive en /stats y Mantenimiento.
    assert has_element?(view, "#kpi-cost", "Costo")
    refute has_element?(view, "#kpi-cost", "UTC")
    refute has_element?(view, "#kpi-cost", "Reinicia en")
  end

  test "today period includes logs from the current UTC day", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    Collector.reset()

    # "Hoy" = día UTC. Un log dentro de esa ventana cuenta; el fallback cubre
    # la primera hora del día UTC, donde `utc_start + 1h` aún está en el futuro.
    utc_start = Periods.start_of_day_utc("Etc/UTC")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    candidate = DateTime.add(utc_start, 3600, :second)

    inserted_at =
      if DateTime.compare(candidate, now) == :lt do
        candidate
      else
        fallback = DateTime.add(now, -30, :second)

        if DateTime.compare(fallback, utc_start) == :lt,
          do: DateTime.add(utc_start, 1, :second),
          else: fallback
      end

    group_with_log(%{cost: "0.005", user: admin, inserted_at: inserted_at})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard?period=today")

    render_async(view)

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#kpi-requests")
  end

  test "admin sees analytics charts with traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Admin needs their own group + member + log to see personal data
    %{owner_password: _password} = group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_async(view)

    assert has_element?(view, "#charts-grid")
    assert has_element?(view, "#cost-chart")
    assert has_element?(view, "#requests-chart")

    # Series carry the rollup data (cost + requests) for the ACTIVE window
    assert html =~ "Costo por hora"
    assert html =~ "Requests por hora"

    # SVG bars rendered for the non-zero series
    assert has_element?(view, "#cost-chart svg rect")
    assert has_element?(view, "#requests-chart svg rect")
  end

  test "user scope: sees only their own consumption", %{conn: conn} do
    %{group: _group, owner: owner, member: member, owner_password: password} =
      group_with_log(%{cost: "0.005"})

    # Someone else's log in another group — must not leak into the user's scope
    group_with_log(%{cost: "99.99"})

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#kpi-requests")
    # The user's cost card should show 0.005 (their own), not 99.99
    html = render(view)
    assert html =~ "0.005"
    _ = member
  end

  ## Personal keys on dashboard --------------------------------------------

  test "user sees their own API key on dashboard", %{conn: conn} do
    %{group: group, owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ group.name
    assert has_element?(view, "#group-#{group.id}")
    assert html =~ "••••"
    _ = member
  end

  test "revoking issues a new key and shows its token once", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password, token: old_token} =
      group_with_member()

    loaded = Accounts.get_group_member!(member.id, :with_assoc)
    old_key_id = loaded.api_key.id

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # The card offers the lifecycle ONCE: revoke and delete, no "regenerate".
    assert has_element?(view, "#revoke-#{member.id}")
    assert has_element?(view, "#hide-#{member.id}")
    refute has_element?(view, "#replace-#{member.id}")

    html = view |> element("#revoke-#{member.id}") |> render_click()

    assert html =~ "Clave revocada. Se emitió una nueva"
    assert html =~ "Nueva clave generada"
    assert has_element?(view, "#new-token-alert")
    # Aviso de éxito (clave creada), no de advertencia.
    assert has_element?(view, "#new-token-alert.alert-success")
    assert has_element?(view, "#new-token-value")

    # The old row is REVOKED (kept for attribution), the old token is dead and
    # a brand-new active row exists for the same user.
    assert Accounts.get_api_key!(old_key_id).status == "revoked"
    assert {:error, :not_found} = Accounts.get_group_member_by_api_key(old_token)

    active = Accounts.list_api_keys_for_user(owner.id)
    assert [replacement] = active
    assert replacement.id != old_key_id
    assert replacement.status == "active"

    # The surface audits the lifecycle action against the key that was voided.
    assert [audit] =
             Tokengate.Auditing.list_audit_logs(%{
               action: "api_key.revoke",
               entity_id: old_key_id
             })

    assert audit.changes["replacement_id"] == replacement.id

    # The card shows the NEW key and keeps both lifecycle actions.
    assert has_element?(view, "#revoke-#{member.id}")
    assert has_element?(view, "#hide-#{member.id}")
    assert has_element?(view, "#api-key-text-#{member.id}", replacement.key_prefix <> "••••")
  end

  test "deleting a key soft-hides it from the card and every listing", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password, token: token} =
      group_with_member()

    loaded = Accounts.get_group_member!(member.id, :with_assoc)
    key_id = loaded.api_key.id

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Activo"

    html = view |> element("#hide-#{member.id}") |> render_click()

    assert html =~ "Clave borrada."

    # Soft-hide: the row still exists (attribution survives) but is invisible
    # everywhere and the token no longer authenticates.
    hidden = Accounts.get_api_key!(key_id)
    refute is_nil(hidden.hidden_at)
    assert hidden.status == "revoked"
    assert Accounts.list_api_keys_for_user(owner.id) == []
    assert {:error, :not_found} = Accounts.get_group_member_by_api_key(token)

    # The card falls back to the "no key" state and offers to issue one.
    refute has_element?(view, "#revoke-#{member.id}")
    refute has_element?(view, "#hide-#{member.id}")
    assert has_element?(view, "#generate-#{member.id}")
  end

  test "dashboard explains the difference between revoking and deleting a key", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} = group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    help = view |> element("#key-actions-help-#{member.id}") |> render()
    assert help =~ "Revocar"
    assert help =~ "Borrar"

    # Revoking keeps the card populated (with the replacement key): the help
    # and both actions stay, there is no dead end.
    view |> element("#revoke-#{member.id}") |> render_click()
    assert has_element?(view, "#key-actions-help-#{member.id}")
    assert has_element?(view, "#revoke-#{member.id}")

    # Deleting removes the key: the help disappears and only "generate" stays.
    view |> element("#hide-#{member.id}") |> render_click()
    refute has_element?(view, "#key-actions-help-#{member.id}")
    assert has_element?(view, "#generate-#{member.id}")
  end

  test "the one-time token can be copied from the alert without losing the icon", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} = group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#new-token-alert")

    view |> element("#revoke-#{member.id}") |> render_click()

    # The copy button targets the VISIBLE token (never a mask) and carries its
    # own icon + label, so the copy feedback cannot destroy the icon.
    assert has_element?(view, "#copy-token-btn[data-source='new-token-value']")
    assert has_element?(view, "#copy-token-btn span.hero-clipboard-document")
    assert has_element?(view, "#copy-token-btn [data-copy-label]")
    assert has_element?(view, "#new-token-value")
  end

  test "user cannot revoke another member's key from dashboard", %{conn: conn} do
    %{owner: owner, owner_password: password} = group_with_member()
    %{member: other_member} = group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_click(view, "revoke_key", %{"id" => other_member.id})
    assert html =~ "No autorizado."
  end

  test "user without groups sees empty state, no General auto-created", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    # No group assigned — should show empty state, not auto-create General
    assert has_element?(view, "#no-group-state")
    assert html =~ "No tienes ningún perfil de límites asignado"
    refute html =~ "General", "should not auto-create General group"
    refute html =~ "Endpoint de la API", "should not show endpoint info without group"
    refute has_element?(view, "#api-usage-info")
    refute has_element?(view, "#period-selector")
  end

  ## Groups & budgets on dashboard ------------------------------------------

  test "user sees their group budget with spend bars", %{conn: conn} do
    %{group: group, owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#group-#{group.id}")
    assert html =~ "Gasto mensual"
    _ = member
  end

  ## Group card: no shortcut to /budget/profiles -----------------------------

  # El enlace al hub de subs se retiró: /budget/profiles vive en la
  # live_session :admin y un no-admin rebotaba a /dashboard al pulsarlo.
  # La tarjeta ya no lleva flecha para ningún rol.
  test "the group card never links to /budget/profiles", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    # Un usuario pertenece a UNA sola sub: una membresía por usuario basta
    # para poblar la tarjeta del dashboard.
    %{group: admin_group} = group_with_log(%{user: admin})

    admin_conn = login(conn, admin, admin_password)
    {:ok, admin_view, _html} = live(admin_conn, ~p"/dashboard")

    # Scoped to the card: the sidebar DOES link to /budget/profiles for admins.
    refute has_element?(admin_view, "#group-#{admin_group.id} a[href='/budget/profiles']")

    %{user: user, password: user_password} = register("user")
    %{group: user_group} = group_with_log(%{user: user})

    user_conn = login(build_conn(), user, user_password)
    {:ok, user_view, _html} = live(user_conn, ~p"/dashboard")

    refute has_element?(user_view, "#group-#{user_group.id} a[href='/budget/profiles']")
  end

  test "the supervised-services card points at /services/supervised", %{conn: conn} do
    %{user: user, password: password} = register("user")
    _group = group_with_log(%{user: user})

    u = unique()
    {:ok, service} = Accounts.create_service(%{name: "Bot #{u}"})
    {:ok, _} = Accounts.add_service_supervisor(service.id, user.id)

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#supervised-services-card[href='/services/supervised']")
  end

  ## Group card: the masked key, without a copy affordance --------------------

  # The card only knows the PREFIX (the token is not stored in clear text), so
  # a copy button there could only copy a mask that does not authenticate —
  # F20's "Copy API key" lie. The copy affordance lives where the token does:
  # the one-time alert (`#copy-token-btn`), covered by its own test.
  test "the API key row shows the masked prefix and offers no mask copy", %{conn: conn} do
    %{group: group, owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    text_id = "api-key-text-#{member.id}"
    row_id = "api-key-row-#{member.id}"

    assert has_element?(view, "##{row_id} code##{text_id}")
    # La fila está separada de la etiqueta, no la contiene.
    refute has_element?(view, "##{row_id} p")
    # No hay botón que "copie" la máscara.
    refute has_element?(view, "#copy-key-#{member.id}")

    member = Accounts.get_group_member!(member.id, :with_assoc)
    prefix = member.api_key.key_prefix
    assert html =~ "#{prefix}••••"
    _ = group
  end

  ## Topbar: cuenta en modal (reemplaza a la página /profile) -----------------

  test "the topbar avatar opens the account modal instead of linking to /profile", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    # El botón de la página /profile se retiró junto con la página.
    refute has_element?(view, "#profile-button")

    assert has_element?(view, "#profile-avatar-button[phx-click='open_profile']")
    assert has_element?(view, "#profile-modal-dialog.modal")
    assert has_element?(view, "#profile-password-form")
    assert html =~ user.email
  end

  test "both avatars are true circles (matching width and height)", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # daisyUI solo dimensiona `.avatar > div`, así que el círculo no puede
    # depender de esa clase: necesita ancho Y alto explícitos e iguales.
    # `w-9` sin alto daba una píldora de 36×24 (y `w-12`, 48×24 en el modal).
    for {id, size} <- [{"#profile-avatar-button", "9"}, {"#profile-modal-dialog", "12"}] do
      css = "#{id} span.bg-primary.w-#{size}.h-#{size}.rounded-full"
      assert has_element?(view, css), "avatar no cuadrado en #{id}"
    end
  end

  test "the modal shows account data and the change-password form", %{conn: conn} do
    %{user: user, password: password} = register("admin")

    conn = login(conn, user, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#profile-modal-title", user.name)
    assert has_element?(view, "#profile-password-form input[name='profile[current_password]']")
    assert has_element?(view, "#profile-password-form input[name='profile[password]']")
    assert has_element?(view, "#save-password-btn")
    assert html =~ "Cambiar contraseña"
    assert html =~ "Administrador"
  end

  test "the modal opens and closes through the component state", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Cerrado: el servidor lo dice y el hook .ProfileModal no lo abre.
    assert has_element?(view, "#profile-modal-dialog.modal[data-open='false']")

    view |> element("#profile-avatar-button") |> render_click()
    assert has_element?(view, "#profile-modal-dialog[data-open='true']")

    # El hook avisa del cierre nativo (Esc / backdrop / X).
    view |> with_target("#profile-modal") |> render_click("close_modal", %{})
    assert has_element?(view, "#profile-modal-dialog[data-open='false']")
  end

  test "reopening the modal clears the previous form state", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("#profile-avatar-button") |> render_click()

    html =
      view
      |> element("#profile-password-form")
      |> render_submit(%{
        "profile" => %{
          "current_password" => "no-es-la-mia-#{unique()}",
          "password" => "Password123456"
        }
      })

    assert html =~ "no es correcta"

    view |> with_target("#profile-modal") |> render_click("close_modal", %{})
    view |> element("#profile-avatar-button") |> render_click()

    refute render(view) =~ "no es correcta"
  end

  test "the modal changes the password with the right current one", %{conn: conn} do
    %{user: user, password: password} = register("user")
    new_password = "password-nueva-#{unique()}1"

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html =
      view
      |> element("#profile-password-form")
      |> render_submit(%{
        "profile" => %{"current_password" => password, "password" => new_password}
      })

    assert html =~ "Contraseña actualizada."
    assert has_element?(view, "#profile-password-saved")

    assert {:ok, _} = Accounts.authenticate_user(user.email, new_password)
    assert {:error, :unauthorized} = Accounts.authenticate_user(user.email, password)
  end

  test "resubmitting password form after validation error preserves profile namespace", %{
    conn: conn
  } do
    %{user: user, password: password} = register("user")
    new_password = "password-nueva-#{unique()}2"

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("#profile-avatar-button") |> render_click()

    html =
      view
      |> element("#profile-password-form")
      |> render_submit(%{
        "profile" => %{
          "current_password" => "wrong-#{unique()}",
          "password" => new_password
        }
      })

    assert html =~ "no es correcta"
    assert has_element?(view, "#profile-password-form input[name='profile[current_password]']")

    html =
      view
      |> element("#profile-password-form")
      |> render_submit(%{
        "profile" => %{
          "current_password" => password,
          "password" => new_password
        }
      })

    assert html =~ "Contraseña actualizada."
    assert {:ok, _} = Accounts.authenticate_user(user.email, new_password)
  end

  test "the modal rejects a wrong current password", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html =
      view
      |> element("#profile-password-form")
      |> render_submit(%{
        "profile" => %{
          "current_password" => "no-es-la-mia-#{unique()}",
          "password" => "Password123456"
        }
      })

    refute html =~ "Contraseña actualizada."
    assert html =~ "no es correcta"
    assert {:ok, _} = Accounts.authenticate_user(user.email, password)
  end

  ## Gestión de llaves propias (botón «Gestionar llaves») -------------------

  test "el dashboard abre el panel de llaves del usuario logueado", %{conn: conn} do
    %{group: group, owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # El botón vive en la tarjeta; el modal no está en el DOM hasta abrirlo.
    assert has_element?(view, "#manage-keys-#{group.id}")
    refute has_element?(view, "#user-keys-modal")

    view |> element("#manage-keys-#{group.id}") |> render_click()

    assert has_element?(view, "#user-keys-modal")
    assert has_element?(view, "#new-key-form")

    # La llave ya existente del usuario se lista en el panel, con las MISMAS
    # acciones que en servicios: renombrar, revocar (=emitir otra) y borrar.
    member = Accounts.get_group_member!(member.id, :with_assoc)
    key_id = member.api_key.id
    assert has_element?(view, "#key-#{key_id}")
    assert has_element?(view, "#rename-key-#{key_id}")
    assert has_element?(view, "#revoke-key-#{key_id}")
    assert has_element?(view, "#hide-key-#{key_id}")
  end

  test "el usuario crea y revoca sus llaves desde el dashboard", %{conn: conn} do
    %{group: group, owner: owner, owner_password: password} = group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("#manage-keys-#{group.id}") |> render_click()
    refute has_element?(view, "#new-key-token")

    view
    |> element("#new-key-form")
    |> render_submit(%{"key" => %{"label" => "laptop"}})

    # El token se muestra UNA sola vez, y la clave nueva aparece en la lista.
    assert has_element?(view, "#new-key-token")

    created =
      owner.id
      |> Accounts.list_api_keys_for_user()
      |> Enum.find(&(&1.label == "laptop"))

    assert created
    assert has_element?(view, "#key-#{created.id}")

    view |> render_click("revoke_user_key", %{"key-id" => created.id})

    # Revocar = emitir otra: la fila vieja sale de la lista (queda revocada) y
    # el token de la nueva se muestra una vez en el panel.
    refute has_element?(view, "#key-#{created.id}")
    assert has_element?(view, "#new-key-token")
    assert Accounts.get_api_key(created.id).status == "revoked"

    replacement =
      owner.id
      |> Accounts.list_api_keys_for_user()
      |> Enum.find(&(&1.label == "laptop"))

    assert replacement
    assert replacement.id != created.id
    assert has_element?(view, "#key-#{replacement.id}")
  end

  test "el panel renombra y borra las llaves del usuario", %{conn: conn} do
    %{group: group, owner: owner, owner_password: password} = group_with_member()

    key =
      owner.id
      |> Accounts.list_api_keys_for_user()
      |> List.first()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("#manage-keys-#{group.id}") |> render_click()

    # Rename: pencil opens the inline form, submit saves through the context
    # (which audits `api_key.rename` with the old/new label).
    view |> element("#rename-key-#{key.id}") |> render_click()
    assert has_element?(view, "#rename-key-form-#{key.id}")

    view
    |> form("#rename-key-inline-#{key.id}", %{"key-id" => key.id, key: %{label: "prod"}})
    |> render_submit()

    assert Accounts.get_api_key(key.id).label == "prod"
    assert has_element?(view, "#key-#{key.id}", "prod")

    # The context owns the audit: old/new label, same entry services produce.
    assert [audit] =
             Tokengate.Auditing.list_audit_logs(%{
               action: "api_key.rename",
               entity_id: key.id
             })

    assert audit.changes["old_label"] == key.label
    assert audit.changes["new_label"] == "prod"

    # Delete: soft-hide, the row leaves the panel and nothing is listed.
    view |> element("#hide-key-#{key.id}") |> render_click()

    refute has_element?(view, "#key-#{key.id}")
    assert Accounts.list_api_keys_for_user(owner.id) == []
    refute is_nil(Accounts.get_api_key(key.id).hidden_at)
  end

  test "un usuario no puede revocar la llave de otro desde el dashboard", %{conn: conn} do
    %{owner: owner, owner_password: password} = group_with_member()
    %{owner: other_owner} = group_with_member()

    other_key = Accounts.list_api_keys_for_user(other_owner.id) |> List.first()
    assert other_key

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_click(view, "revoke_user_key", %{"key-id" => other_key.id})

    assert html =~ "Clave no encontrada."
    # La llave ajena sigue activa.
    assert Accounts.get_api_key(other_key.id).status == "active"
  end

  ## Marca del laboratorio en el desglose por modelo ------------------------

  test "el desglose por modelo muestra el logo del laboratorio", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    u = unique()

    {:ok, lab} =
      Providers.create_custom_lab(%{
        "name" => "Lab #{u}",
        "key" => "lab-#{u}",
        "logo_url" => "https://logos.test/#{u}.svg"
      })

    {:ok, model} =
      Providers.create_model(%{
        name: "modelo-#{u}",
        context_window: 128_000,
        lab_key: lab.key
      })

    fixture = group_with_log(%{cost: "0.005", user: admin})

    # Un log con `model_id` real: el desglose resuelve id + nombre del catálogo y
    # la marca sale del lab vinculado.
    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: fixture.member.id,
        provider_id: fixture.provider.id,
        model_id: model.id,
        model_requested: model.name,
        model_responded: model.name,
        agent_type: "claude-code",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: Decimal.new("0.005"),
        latency_ms: 42,
        streaming: false,
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    assert has_element?(
             view,
             "#bd-model-mark-#{model.id} img[src='https://logos.test/#{u}.svg']"
           )
  end

  test "el desglose cae al icono genérico cuando el modelo no tiene marca", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Sin `model_id`, el desglose agrupa bajo el id nulo: no hay marca que
    # resolver, así que se pinta el icono genérico del modelo.
    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    assert has_element?(view, "#bd-model-mark-unknown")
  end

  # Las tarjetas de presupuesto se re-leen en cada cambio de período y en cada
  # reload de pubsub. Antes se calculaban sólo al montar, así que mostraban el
  # gasto del instante del mount hasta recargar la página entera.
  test "la tarjeta de presupuesto se re-lee al cambiar de período", %{conn: conn} do
    u = unique()

    {:ok, group} =
      Accounts.create_group(%{name: "Budget #{u}", monthly_spend_limit_usd: "100.00"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "budget-owner-#{u}@example.com",
        name: "Budget Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        user_id: owner.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("10.00")
      })

    conn = login(conn, owner, "password-secret-#{u}1")
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#group-#{group.id}", "10.0000 / 100.0000")

    # Gasto nuevo después del mount. La invalidación salta el TTL de 5 s del
    # DashboardCache para que la aserción mida el refresco de la tarjeta, no el
    # vencimiento de la caché.
    {:ok, _} =
      Logs.log_request(%{
        group_member_id: member.id,
        user_id: owner.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("5.00")
      })

    Tokengate.Metrics.DashboardCache.invalidate_all()

    # Any period patch re-reads the card: 30d is a different window than the
    # default (week), so `handle_params/3` reloads the personal data.
    view |> element("#period-30d") |> render_click()

    # El número se re-lee junto con la tarjeta. `has_element?` normaliza el
    # `<span>` interno del componente compartido, que separa gasto de techo.
    assert has_element?(view, "#group-#{group.id}", "15.0000 / 100.0000")
  end
end
