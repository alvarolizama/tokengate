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

  defp group_with_member(opts \\ %{}) do
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

    {:ok, _api_key, _token} = Accounts.replace_api_key(member)

    %{group: group, owner: owner, member: member, owner_password: "password-secret-#{u}1"}
  end

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard")
  end

  test "admin sees the dashboard shell and empty state with no traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Dashboard"
    assert has_element?(view, "#empty-state")
    assert html =~ "Aún no hay requests"
  end

  test "admin sees period selector with all options", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#period-selector")
    assert has_element?(view, "#period-today")
    assert has_element?(view, "#period-7d")
    assert has_element?(view, "#period-30d")
    assert has_element?(view, "#period-90d")
    _ = html
  end

  test "admin sees metric cards when there is traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Insert a log for the ADMIN's own membership (user-wide scope)
    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

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

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Un usuario tiene UNA sub: las dos ventanas se insertan como logs de la
    # misma membresía, con distinto `inserted_at`.
    fixture =
      group_with_log(%{
        cost: "0.005",
        user: admin,
        inserted_at: DateTime.add(now, -3600, :second)
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
        inserted_at: DateTime.add(now, -8 * 86_400, :second)
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    view |> element("#period-7d") |> render_click()
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
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#empty-state")
    assert html =~ "Aún no hay requests"
  end

  test "admin with no memberships sees empty state", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

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

    assert has_element?(view, "#breakdown-tabs")
    assert has_element?(view, "#tab-model")
    assert has_element?(view, "#tab-member")
    # Group breakdown is not shown on the personal dashboard
    refute has_element?(view, "#tab-group")
  end

  test "switching breakdown tab shows the right table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Default is model
    html = render(view)
    assert html =~ "bd-model-"

    # Switch to member
    view |> element("#tab-member") |> render_click()
    html = render(view)
    assert html =~ "bd-member-"

    # Group tab is not rendered on the personal dashboard
    refute has_element?(view, "#tab-group")
  end

  test "switching period reloads metrics", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    # Default period is today — chart title reflects it
    assert html =~ "Costo por hora"

    # Switch to 30d — the click replies instantly with a loading state
    # (micro-spinner on the active button); the bundle lands async.
    html = view |> element("#period-30d") |> render_click()
    assert html =~ ~s(class="loading loading-spinner loading-xs")

    html = render_async(view)
    assert html =~ "Costo por día (30d)"
    refute html =~ ~s(class="loading loading-spinner loading-xs")
  end

  test "period switch keeps stale data visible while loading", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Mid-flight switch: previous bundle stays on screen (dimmed), and the
    # chart titles still describe the displayed ("today") period.
    html = view |> element("#period-30d") |> render_click()
    assert html =~ "opacity-60"
    assert html =~ "Costo por hora"

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
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#empty-state")
  end

  test "dashboard: el KPI de costo muestra solo el gasto del período", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "America/Mexico_City")
    Collector.reset()

    group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

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
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "#empty-state")
    assert has_element?(view, "#kpi-requests")
  end

  test "admin sees analytics charts with traffic", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    Collector.reset()

    # Admin needs their own group + member + log to see personal data
    %{owner_password: _password} = group_with_log(%{cost: "0.005", user: admin})

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#charts-grid")
    assert has_element?(view, "#cost-chart")
    assert has_element?(view, "#requests-chart")

    # Series carry the rollup data (cost + requests)
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

  test "user can replace their key from dashboard", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = view |> element("#replace-#{member.id}") |> render_click()

    assert html =~ "Nueva clave generada"
    assert has_element?(view, "#new-token-alert")
    # Aviso de éxito (clave creada), no de advertencia.
    assert has_element?(view, "#new-token-alert.alert-success")
    assert has_element?(view, "#new-token-value")
  end

  test "user can revoke their key from dashboard", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Activa"

    html = view |> element("#revoke-#{member.id}") |> render_click()
    assert html =~ "Revocada"
    refute has_element?(view, "#revoke-#{member.id}")
  end

  test "dashboard explains the difference between regenerating and revoking a key", %{conn: conn} do
    %{owner: owner, member: member, owner_password: password} = group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#replace-#{member.id}")
    assert has_element?(view, "#revoke-#{member.id}")

    help = view |> element("#key-actions-help-#{member.id}") |> render()
    assert help =~ "Regenerar"
    assert help =~ "Revocar"

    html = view |> element("#revoke-#{member.id}") |> render_click()
    assert html =~ "Revocada"

    # Sin clave activa no hay nada que revocar: la aclaración desaparece y
    # queda únicamente la acción de regenerar.
    refute has_element?(view, "#key-actions-help-#{member.id}")
    assert has_element?(view, "#replace-#{member.id}")
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

  ## Group card: copy button next to the API key ----------------------------

  test "the API key row has a copy button targeting the masked key", %{conn: conn} do
    %{group: group, owner: owner, member: member, owner_password: password} =
      group_with_member()

    conn = login(conn, owner, password)
    {:ok, view, html} = live(conn, ~p"/dashboard")

    copy_id = "copy-key-#{member.id}"
    text_id = "api-key-text-#{member.id}"
    row_id = "api-key-row-#{member.id}"

    # Ambos en la MISMA fila, y la clave antes del botón: el botón va al lado
    # de la clave, no junto a la etiqueta "CLAVE API".
    assert has_element?(view, "##{row_id} code##{text_id}")
    assert has_element?(view, "##{row_id} button##{copy_id}[data-target='#{text_id}']")
    assert has_element?(view, "##{copy_id}")

    # La fila está separada de la etiqueta, no la contiene.
    refute has_element?(view, "##{row_id} p")

    row_html = view |> element("##{row_id}") |> render()
    assert elem(:binary.match(row_html, text_id), 0) < elem(:binary.match(row_html, copy_id), 0)

    # The masked prefix shown on the card is what the button copies.
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

    # La llave ya existente del usuario se lista en el panel.
    member = Accounts.get_group_member!(member.id, :with_assoc)
    assert has_element?(view, "#key-#{member.api_key.id}")
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

    # Revocada: sale de la lista (solo se listan las activas).
    refute has_element?(view, "#key-#{created.id}")
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

    view |> element("#period-7d") |> render_click()

    # El número se re-lee junto con la tarjeta. `has_element?` normaliza el
    # `<span>` interno del componente compartido, que separa gasto de techo.
    assert has_element?(view, "#group-#{group.id}", "15.0000 / 100.0000")
  end
end
