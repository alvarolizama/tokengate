defmodule TokengateWeb.GroupsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "groups-#{u}@example.com",
        name: "Groups #{u}",
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

  defp group_fixture(attrs \\ %{}) do
    u = unique()

    {:ok, model} =
      Providers.create_model(%{
        name: "gpt-#{u}",
        context_window: 128_000
      })

    {:ok, group} =
      Accounts.create_group(Map.merge(%{name: "Group #{u}"}, attrs))

    %{group: group, model: model}
  end

  # --------------------------------------------------------------------------
  # Access control
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/budget/profiles")
  end

  test "non-admin authenticated users are redirected to /dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/budget/profiles")
  end

  # --------------------------------------------------------------------------
  # Mount and render
  # --------------------------------------------------------------------------

  test "admin sees the groups page with empty state via search filter", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/budget/profiles")

    assert html =~ "Perfiles de límites"
    assert has_element?(view, "#new-group-btn")

    # Type a search term that matches no group → triggers empty state deterministically
    no_match_term = "zzz-no-match-#{System.unique_integer([:positive])}"

    # El binding vive en el FORM (`admin_search` -> `#search-form` con `name="q"`).
    assert has_element?(view, "#search-form input[name='q']")

    view
    |> element("#search-form")
    |> render_change(%{"q" => no_match_term})

    assert has_element?(view, "#groups-empty")
  end

  test "admin sees existing groups in the stream", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/budget/profiles")

    assert html =~ group.name
    assert has_element?(view, "#edit-#{group.id}")

    # Contrato `.table` (antes eran cards): tbody `#groups` con los headers
    # del listado y una fila por perfil de límites.
    assert has_element?(view, "#groups")
    assert has_element?(view, "table th", "Perfil de límites")
    assert has_element?(view, "table th", "Miembros")
    assert has_element?(view, "table th", "Límites")
    assert has_element?(view, "table th", "Gasto/mes")
    assert has_element?(view, "#group-credit-#{group.id}")
    assert has_element?(view, "#edit-models-#{group.id}")
  end

  # --------------------------------------------------------------------------
  # CRUD — Create
  # --------------------------------------------------------------------------

  test "admin creates a group", %{conn: conn} do
    group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#new-group-btn") |> render_click()
    # El contenedor es el .modal único: su id va en el div raíz.
    assert has_element?(view, "#group-form-modal")
    assert has_element?(view, "#group-form")

    html =
      view
      |> form("#group-form", %{
        group: %{
          name: "Mi Nuevo Grupo",
          default_concurrency_limit: 10,
          default_rpm_limit: 120
        }
      })
      |> render_submit()

    assert html =~ "Perfil de límites creado"
    assert html =~ "Mi Nuevo Grupo"
  end

  test "create with invalid params shows errors", %{conn: conn} do
    group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#new-group-btn") |> render_click()

    html =
      view
      |> form("#group-form", %{
        group: %{
          name: ""
        }
      })
      |> render_submit()

    # Form stays open with errors
    assert has_element?(view, "#group-form")
    _ = html
  end

  # --------------------------------------------------------------------------
  # CRUD — Update
  # --------------------------------------------------------------------------

  test "admin edits a group", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#edit-#{group.id}") |> render_click()
    assert has_element?(view, "#group-form")

    html =
      view
      |> form("#group-form", %{
        group: %{name: "Grupo Renombrado"}
      })
      |> render_submit()

    assert html =~ "Perfil de límites actualizado"
    assert html =~ "Grupo Renombrado"
  end

  test "cancel_form closes the form", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#new-group-btn") |> render_click()
    assert has_element?(view, "#group-form")

    render_click(view, "cancel_form")
    refute has_element?(view, "#group-form")
  end

  # --------------------------------------------------------------------------
  # CRUD — Delete
  # --------------------------------------------------------------------------

  test "admin deletes a group", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    assert has_element?(view, "#delete-#{group.id}")

    view |> element("#delete-#{group.id}") |> render_click()
    assert has_element?(view, "#delete-group-modal")
    assert has_element?(view, "#delete-group-name", group.name)
    assert has_element?(view, "#confirm-delete-group")

    html = view |> element("#confirm-delete-group") |> render_click()

    assert html =~ "Perfil de límites eliminado"
    refute has_element?(view, "#delete-#{group.id}")
  end

  test "cancel delete closes confirmation modal without deleting", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#delete-#{group.id}") |> render_click()
    assert has_element?(view, "#delete-group-modal")

    view |> element("#cancel-delete-group") |> render_click()
    refute has_element?(view, "#delete-group-modal")
    assert Accounts.get_group(group.id) != nil
  end

  # --------------------------------------------------------------------------
  # Group model model assignment
  # --------------------------------------------------------------------------

  test "admin toggles a model grant on a group via the models modal", %{conn: conn} do
    %{group: group, model: model_} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/budget/profiles")

    # The model picker is NOT in the card — only inside the models modal
    refute html =~ "Modelos del perfil de límites</h4>"
    refute has_element?(view, "#model-picker-#{group.id}-#{model_.id}")

    # Open the models modal from the group card header
    view |> element("#edit-models-#{group.id}") |> render_click()
    assert has_element?(view, "#models-modal-#{group.id}")
    assert has_element?(view, "#model-picker-#{group.id}-#{model_.id}")

    # Grant the model
    html =
      view
      |> element("#model-picker-#{group.id}-#{model_.id}")
      |> render_click()

    assert html =~ "Modelos actualizados"

    # Verify the grant was persisted
    grant =
      Repo.get_by(
        Tokengate.Providers.GroupModel,
        group_id: group.id,
        model_id: model_.id
      )

    assert grant != nil

    # Toggle again to revoke
    html =
      view
      |> element("#model-picker-#{group.id}-#{model_.id}")
      |> render_click()

    assert html =~ "Modelos actualizados"

    refute Repo.get_by(
             Tokengate.Providers.GroupModel,
             group_id: group.id,
             model_id: model_.id
           )
  end

  test "link to members page is present", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    assert has_element?(view, "#members-link-#{group.id}")

    # El enlace apunta a la URL nueva del perfil de límites (no a la vieja
    # /budget/months, que hoy sólo funciona por redirect).
    assert has_element?(
             view,
             "#members-link-#{group.id}[href=\"/budget/profiles/#{group.id}/members\"]"
           )
  end

  # --------------------------------------------------------------------------
  # Webhooks — global now: they no longer hang off a group
  # --------------------------------------------------------------------------

  test "the group card has no webhooks badge", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    # La observabilidad es de toda la instalación, así que un webhook no
    # pertenece a la sub y la tarjeta no lleva contador ni enlace.
    refute has_element?(view, "#webhooks-link-#{group.id}")
  end

  # --------------------------------------------------------------------------
  # Monthly limit — editable from the sub form (comment 2 on the Editar button)
  # --------------------------------------------------------------------------

  test "the edit modal carries the monthly spend limit", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#edit-#{group.id}") |> render_click()

    assert has_element?(view, "#group-form input[name='group[monthly_spend_limit_usd]']")
    assert has_element?(view, "#group-form input[name='group[unlimited_spend]']")
  end

  test "admin sets the group monthly limit", %{conn: conn} do
    %{group: group} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    view |> element("#edit-#{group.id}") |> render_click()

    view
    |> form("#group-form", %{
      group: %{name: group.name, monthly_spend_limit_usd: "250.50"}
    })
    |> render_submit()

    assert Accounts.get_group!(group.id).monthly_spend_limit_usd == Decimal.new("250.50")
  end

  # --------------------------------------------------------------------------
  # Ids del cliente (F6): un id no-UUID o inexistente no mata la LiveView
  # --------------------------------------------------------------------------

  test "malformed and unknown ids never crash the profile handlers", %{conn: conn} do
    %{group: group, model: model_} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    for {event, params} <- [
          {"edit_group", %{"id" => "no-es-un-uuid"}},
          {"edit_models", %{"id" => "no-es-un-uuid"}},
          {"delete_group", %{"id" => "no-es-un-uuid"}},
          {"toggle_model", %{"target-id" => "no-es-un-uuid", "model-id" => model_.id}},
          {"edit_group", %{"id" => Ecto.UUID.generate()}},
          {"delete_group", %{"id" => Ecto.UUID.generate()}}
        ] do
      html = render_hook(view, event, params)
      assert html =~ "Perfil de límites no encontrado"
    end

    # La vista sigue viva y el perfil real sigue en su sitio.
    assert has_element?(view, "#edit-#{group.id}")
    refute has_element?(view, "#group-form")
  end

  test "toggle_model refreshes the model count badge inside the groups stream", %{conn: conn} do
    %{group: group, model: model_} = group_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    assert has_element?(view, "#groups-#{group.id}", "0 modelos")

    render_hook(view, "toggle_model", %{"target-id" => group.id, "model-id" => model_.id})

    assert has_element?(view, "#groups-#{group.id}", "1 modelos")
  end

  # --------------------------------------------------------------------------
  # Pagination, sorting, canonical budget & navigation links
  # --------------------------------------------------------------------------

  test "paginates limit profiles in DB with 30 per page", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    prefix = "000 Paged Profile #{unique()}"
    baseline = length(Accounts.list_groups())
    to_create = max(31 - baseline, 1)

    groups =
      for i <- 1..to_create do
        pad = i |> Integer.to_string() |> String.pad_leading(3, "0")
        {:ok, g} = Accounts.create_group(%{name: "#{prefix} #{pad}"})
        g
      end

    total = baseline + to_create
    first = hd(groups)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    assert has_element?(view, "#groups-pagination")
    assert has_element?(view, "#groups-pagination-range", "1–30 de #{total}")
    assert has_element?(view, "#groups-#{first.id}")

    view |> element("#groups-pagination-page-2") |> render_click()

    assert has_element?(view, "#groups-pagination-range", "31–#{total} de #{total}")
    refute has_element?(view, "#groups-#{first.id}")
  end

  test "sorts by name, members, and spend", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, g_low} = Accounts.create_group(%{name: "Alpha Low"})
    {:ok, g_high} = Accounts.create_group(%{name: "Zeta High"})

    %{user: u1} = register("user")
    %{user: u2} = register("user")
    {:ok, m1} = Accounts.create_group_member(%{user_id: u1.id, group_id: g_high.id})
    {:ok, _m2} = Accounts.create_group_member(%{user_id: u2.id, group_id: g_low.id})

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        group_member_id: m1.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("25.00"),
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    assert has_element?(view, "th button[phx-click='sort_groups'][phx-value-field='name']")
    assert has_element?(view, "th button[phx-click='sort_groups'][phx-value-field='members']")
    assert has_element?(view, "th button[phx-click='sort_groups'][phx-value-field='spend']")

    html = view |> element("th button[phx-value-field='spend']") |> render_click()
    assert html =~ "▼"

    ids =
      Regex.scan(~r/<tr[^>]+id="groups-([^"]+)"/, html)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.filter(&(&1 in [g_high.id, g_low.id]))

    assert ids == [g_high.id, g_low.id]
  end

  test "members count cell and stats icon link to members and stats pages, and credit renders canonical badges/bar",
       %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{group: budgeted} = group_fixture(%{monthly_spend_limit_usd: "100.00"})
    %{group: unlimited} = group_fixture(%{unlimited_spend: true})
    %{group: no_budget} = group_fixture()

    %{user: u1} = register("user")
    {:ok, m1} = Accounts.create_group_member(%{user_id: u1.id, group_id: budgeted.id})

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        group_member_id: m1.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("10.00"),
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/budget/profiles")

    assert has_element?(
             view,
             "#members-count-link-#{budgeted.id}[href=\"/budget/profiles/#{budgeted.id}/members\"]",
             "1"
           )

    assert has_element?(
             view,
             "#stats-#{budgeted.id}[href=\"/stats/profiles/#{budgeted.id}\"]"
           )

    assert has_element?(view, "#group-credit-#{budgeted.id}", "OK")
    assert has_element?(view, "#group-credit-#{unlimited.id}", "Ilimitado")
    assert has_element?(view, "#group-credit-#{no_budget.id}", "Sin presupuesto")
  end
end
