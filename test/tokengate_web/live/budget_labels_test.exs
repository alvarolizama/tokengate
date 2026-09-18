defmodule TokengateWeb.BudgetLabelsTest do
  @moduledoc """
  El vocabulario de presupuesto en la UI: «sin presupuesto» no es «sin límite».

  Fija la regla y las etiquetas que la expresan:

    * un sujeto **sin presupuesto mensual y sin top-up** se lee «Sin presupuesto»
      (no tiene camino de gasto: el proxy responde 402);
    * **con top-up** se lee su crédito de top-up (esa es la excepción);
    * **con presupuesto mensual** se lee su techo (barra de consumo);
    * **ilimitado** solo se consigue por el presupuesto mensual al que pertenece
      (o por el flag propio, que la UI no expone).

  Y el renombre de vocabulario: la sección del sidebar es «Presupuesto»
  (`/budget/*`), el contenedor es un «perfil de límites» y las etiquetas
  visibles salen de gettext (el msgid se renderiza tal cual cuando no hay
  traducción; el resto se traduce al español desde un msgid en inglés).
  """

  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Credits, Logs}
  alias Tokengate.Metrics.DashboardCache

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "budget-#{u}@example.com",
        name: "Budget #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # El idioma por defecto de la UI es inglés; este archivo afirma el
    # vocabulario en español, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp group_fixture(attrs) do
    {:ok, group} = Accounts.create_group(Map.merge(%{name: "Ppto #{unique()}"}, attrs))
    group
  end

  defp member(group, user) do
    {:ok, _} = Accounts.create_group_member(%{"user_id" => user.id, "group_id" => group.id})
  end

  defp topup(user, amount) do
    {:ok, _} = Credits.Topups.create(%{"user_id" => user.id, "amount_usd" => amount})
  end

  defp badge(view, user), do: view |> element("#credit-#{user.id}") |> render() |> String.trim()

  # Solo el texto visible de la celda: fuera etiquetas (y con ellas los
  # `title`/`class`), para poder afirmar sobre la etiqueta sin que el tooltip
  # —que sí nombra el estado— coincida por accidente.
  defp badge_text(view, user) do
    view
    |> badge(user)
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.split()
    |> Enum.join(" ")
  end

  # ---------------------------------------------------------------------------
  # La regla: «Sin presupuesto» solo cuando no hay presupuesto ni top-up
  # ---------------------------------------------------------------------------

  test "la columna de presupuesto distingue los cuatro estados", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    # 1. sin presupuesto mensual y sin top-up
    %{user: naked} = register("user")
    # 2. sin presupuesto mensual, con top-up
    %{user: with_topup} = register("user")
    topup(with_topup, "10.00")
    # 3. con presupuesto mensual
    %{user: with_budget} = register("user")
    member(group_fixture(%{monthly_spend_limit_usd: "50.00"}), with_budget)
    # 4. ilimitado (por el presupuesto mensual al que pertenece)
    %{user: unlimited} = register("user")
    member(group_fixture(%{unlimited_spend: true}), unlimited)

    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/access/users")

    naked_badge = badge_text(view, naked)
    topup_badge = badge_text(view, with_topup)
    budget_badge = badge_text(view, with_budget)
    unlimited_html = badge(view, unlimited)

    IO.puts("sin nada:      #{naked_badge}")
    IO.puts("con top-up:    #{topup_badge}")
    IO.puts("con ppto:      #{budget_badge}")
    IO.puts("ilimitado:     #{unlimited_html}")

    # 1. Sin nada: no hay límite del que hablar — no hay presupuesto.
    assert naked_badge =~ "Sin presupuesto"
    refute naked_badge =~ "Sin límite"

    # 2. Con top-up: la excepción — se lee el crédito que sí tiene.
    assert topup_badge =~ "Top-up $10.00"
    refute topup_badge =~ "Sin presupuesto"
    refute topup_badge =~ "Sin límite"

    # 3. Con presupuesto mensual: su techo y la barra de consumo (consumido /
    # techo, la misma lectura que /stats y el dashboard).
    assert budget_badge =~ "0.0000 / 50.0000"
    refute budget_badge =~ "Sin presupuesto"

    # 4. Ilimitado (y el badge dice de qué cap protege: no es «sin techo»).
    assert unlimited_html =~ "Ilimitado"
    assert unlimited_html =~ "cap global"
  end

  test "un top-up da crédito aunque no haya presupuesto mensual", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: plain} = register("user")
    topup(plain, "25.50")

    # El motor lo confirma: sin techo mensual y con el top-up en orden de
    # drenado (`{:user, id}` es su único camino de gasto).
    assert %{limit_usd: nil, unlimited?: false} = Credits.user_limit(plain, nil)
    assert [%{user_id: user_id}] = Credits.Topups.draining_order({:user, plain.id})
    assert user_id == plain.id

    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/access/users")

    assert badge_text(view, plain) =~ "Top-up $25.50"
  end

  # ---------------------------------------------------------------------------
  # El vocabulario: sección, contenedor y etiquetas (gettext EN → ES)
  # ---------------------------------------------------------------------------

  test "el sidebar agrupa bajo Presupuesto con las rutas /budget/*", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/budget/profiles")

    # Etiqueta de sección traducida (msgid "Budget" → "Presupuesto").
    assert has_element?(view, "#sidebar-section-budget", "Presupuesto")
    refute has_element?(view, "#sidebar-section-credito")

    # Los enlaces de la sección, con su prefijo de URL.
    assert has_element?(view, "#sidebar-link-budget-profiles[href=\"/budget/profiles\"]")
    assert has_element?(view, "#sidebar-link-budget-topups[href=\"/budget/topups\"]")
    # El tope diario global se mudó de Mantenimiento a Presupuesto.
    assert has_element?(view, "#sidebar-link-budget-global[href=\"/budget/global\"]")
    assert has_element?(view, "#sidebar-link-budget-global", "Tope diario global")

    # El drill-down deja el padre encendido.
    profile = group_fixture(%{})

    {:ok, view2, _} =
      live(recycle(conn), ~p"/budget/profiles/#{profile.id}/members")

    assert has_element?(view2, "#sidebar-link-budget-profiles[aria-current=page]")
  end

  test "la página de perfiles de límites se titula en español", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/budget/profiles")

    assert render(view) =~ "Perfiles de límites"

    view |> element("#new-group-btn") |> render_click()
    assert has_element?(view, "#group-form input[name='group[monthly_spend_limit_usd]']")
    assert has_element?(view, "#group-form input[name='group[unlimited_spend]']")
  end

  # El contenedor tiene un solo nombre en toda la UI: el que el usuario ve en
  # Usuarios y en Monitoreo es el mismo que en el sidebar. Sin esto, la
  # etiqueta vuelve a derivar por superficie.
  test "Usuarios y Monitoreo llaman «Perfiles de límites» al contenedor", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    profile = group_fixture(%{name: "Perfil visible #{unique()}"})
    conn = login(conn, admin, password)

    {:ok, users_view, users_html} = live(conn, ~p"/access/users")
    assert users_html =~ "Perfiles de límites"
    refute users_html =~ "Grupos</th>"

    users_view |> element("#groups-#{admin.id}") |> render_click()
    assert render(users_view) =~ "Perfiles de límites de"

    {:ok, monitoring, monitoring_html} = live(recycle(conn), ~p"/operations/monitoring")
    assert monitoring_html =~ "Perfil de límites"
    assert monitoring_html =~ profile.name
  end

  test "el form de usuario llama «Presupuesto mensual» al contenedor", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: plain} = register("user")
    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/access/users")

    view |> element("#edit-#{plain.id}") |> render_click()

    assert has_element?(view, "#user-edit-form select[name='user[sub_id]']")
    assert render(view) =~ "Presupuesto mensual"
    refute render(view) =~ "Sub mensual"

    # El form sigue sin exponer el techo propio: el presupuesto manda.
    refute render(view) =~ "user[unlimited_spend]"
    refute render(view) =~ "user[monthly_spend_limit_usd]"
  end

  # ---------------------------------------------------------------------------
  # El camino de la UI para lo ilimitado, y las desviaciones de la vista
  # ---------------------------------------------------------------------------

  test "ilimitado solo por el presupuesto mensual (camino de la UI)", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: plain} = register("user")
    budget = group_fixture(%{monthly_spend_limit_usd: "50.00"})
    conn = login(conn, admin, password)

    # 1. el presupuesto mensual se marca ilimitado
    {:ok, groups_view, _} = live(conn, ~p"/budget/profiles")
    groups_view |> element("#edit-#{budget.id}") |> render_click()

    groups_view
    |> form("#group-form", %{
      group: %{name: budget.name, monthly_spend_limit_usd: "50.00", unlimited_spend: "true"}
    })
    |> render_submit()

    assert Accounts.get_group!(budget.id).unlimited_spend

    # 2. el usuario se agrega a ese presupuesto
    {:ok, users_view, _} = live(conn, ~p"/access/users")
    assert badge_text(users_view, plain) =~ "Sin presupuesto"

    users_view |> element("#edit-#{plain.id}") |> render_click()

    users_view
    |> form("#user-edit-form", %{
      user: %{name: plain.name, global_role: "user", status: "active", sub_id: budget.id}
    })
    |> render_submit()

    limit = Credits.user_limit(Accounts.get_user!(plain.id), Accounts.get_group!(budget.id))
    IO.puts("user_limit/2 tras agregarlo: #{inspect(limit)}")
    assert limit.unlimited?
    assert limit.source == :group

    # La columna sigue el cambio en cuanto la caché (TTL 5s) se invalida.
    DashboardCache.invalidate_all()
    {:ok, fresh, _} = live(conn, ~p"/access/users")
    assert badge_text(fresh, plain) =~ "Ilimitado"
  end

  test "el read-side refleja el flag propio de un usuario sin presupuesto", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: plain} = register("user")

    # Así lo dejó el backfill `20260916193827_drop_credit_subscriptions`.
    {:ok, plain} = Accounts.update_user(plain, %{"unlimited_spend" => true})

    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/access/users")

    assert Accounts.list_group_members_for_user(plain.id) == []
    assert badge_text(view, plain) =~ "Ilimitado"

    limit = Credits.user_limit(plain, nil)
    assert limit.unlimited?
    assert limit.source == :user
  end

  test "un sujeto con presupuesto agotado y top-up sigue teniendo crédito", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: plain} = register("user")
    budget = group_fixture(%{monthly_spend_limit_usd: "10.00"})
    member(budget, plain)
    topup(plain, "5.00")

    # Gasto que agota el techo, asentado en la verdad durable.
    [membership] = Accounts.list_group_members_for_user(plain.id)

    {:ok, _} =
      Logs.log_request(%{
        group_member_id: membership.id,
        user_id: plain.id,
        subject_type: "user",
        model_requested: "test-model",
        provider_cost_usd: "10.00"
      })

    conn = login(conn, admin, password)
    {:ok, view, _} = live(conn, ~p"/access/users")

    # El techo está agotado: la barra lo refleja, el badge lo dice y no hay
    # «sin presupuesto».
    assert badge_text(view, plain) =~ "10.0000 / 10.0000"
    assert badge_text(view, plain) =~ "Agotado"
    refute badge_text(view, plain) =~ "Sin presupuesto"
  end
end
