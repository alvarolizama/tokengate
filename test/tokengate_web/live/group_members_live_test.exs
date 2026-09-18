defmodule TokengateWeb.GroupMembersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Providers}
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "members-#{u}@example.com",
        name: "Members #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    # Este archivo afirma los mensajes en español del LiveView; el idioma por
    # defecto de la UI es inglés, así que el usuario arranca en español.
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  # Builds org + group + model. The "owner" user is a member of the group.
  defp group_with_member(_opts \\ %{}) do
    u = unique()

    {:ok, model} =
      Providers.create_model(%{
        name: "gpt-#{u}",
        context_window: 128_000
      })

    {:ok, group} = Accounts.create_group(%{name: "Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{
        user_id: owner.id,
        group_id: group.id
      })

    # Provision API key for the member (required for proxy + UI display)
    {:ok, _api_key, _token} = Accounts.replace_api_key(member)
    member = Accounts.get_group_member!(member.id)

    %{
      group: group,
      model: model,
      owner: owner,
      member: member,
      owner_password: "password-secret-#{u}1"
    }
  end

  defp group_url(group), do: "/budget/profiles/#{group.id}/members"

  # --------------------------------------------------------------------------
  # Access control
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    %{group: group} = group_with_member()
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, group_url(group))
  end

  test "non-admin user is denied access", %{conn: conn} do
    %{group: group, owner: owner, owner_password: password} = group_with_member()

    conn = login(conn, owner, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, group_url(group))
  end

  # --------------------------------------------------------------------------
  # Admin access and render
  # --------------------------------------------------------------------------

  test "admin sees members of any group", %{conn: conn} do
    %{group: group, owner: owner} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, group_url(group))

    assert html =~ "Miembros de #{group.name}"
    assert html =~ owner.email
    assert has_element?(view, "#new-member-btn")
  end

  # --------------------------------------------------------------------------
  # Add member
  # --------------------------------------------------------------------------

  test "admin adds a member by email", %{conn: conn} do
    %{group: group} = group_with_member()
    %{user: admin, password: password} = register("admin")

    # Register a separate user to add
    %{user: new_user} = register("user")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert view |> element("#new-member-btn") |> render_click()

    html =
      view
      |> form("#add-member-form", %{"add_member[email]" => new_user.email})
      |> render_submit()

    assert html =~ "Miembro añadido"
    assert html =~ new_user.email

    # La membresía se crea sin key ni extras: las keys cuelgan del usuario y
    # los límites los aporta la sub.
    member =
      Repo.get_by(
        Tokengate.Accounts.GroupMember,
        user_id: new_user.id,
        group_id: group.id
      )

    assert member != nil
    # La membresía ya no guarda límites propios: el effective sale del usuario
    # (`propio || contenedor || default`) y, sin propios, hereda de la sub.
    refute Map.has_key?(member, :extra_concurrency)
    refute Map.has_key?(member, :extra_rpm)
    assert Repo.get!(Tokengate.Accounts.User, new_user.id).default_concurrency_limit == nil

    api_key = Repo.get_by(Tokengate.Accounts.ApiKey, group_member_id: member.id)
    assert api_key == nil
  end

  # La invariante «un usuario = una sub mensual» sale como error de índice
  # único; la UI lo traduce a algo accionable en vez del críptico "has already
  # been taken".
  test "adding a user who already has another sub shows an actionable error", %{conn: conn} do
    %{group: group} = group_with_member()
    %{user: admin, password: password} = register("admin")

    %{user: taken} = register("user")
    {:ok, other_sub} = Accounts.create_group(%{name: "Otra Sub #{unique()}"})
    {:ok, _} = Accounts.create_group_member(%{user_id: taken.id, group_id: other_sub.id})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    view |> element("#new-member-btn") |> render_click()

    html =
      view
      |> form("#add-member-form", %{"add_member[email]" => taken.email})
      |> render_submit()

    assert html =~ "ya pertenece a otro perfil de límites"
    refute Repo.get_by(Tokengate.Accounts.GroupMember, user_id: taken.id, group_id: group.id)
  end

  test "add member modal can be cancelled", %{conn: conn} do
    %{group: group} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert view |> element("#new-member-btn") |> render_click()
    assert has_element?(view, "#add-member-modal")

    html = view |> element("#cancel-add-member") |> render_click()
    refute html =~ "add-member-modal"
  end

  test "add member with non-existent email shows error", %{conn: conn} do
    %{group: group} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert view |> element("#new-member-btn") |> render_click()

    html =
      view
      |> form("#add-member-form", %{
        "add_member[email]" => "nonexistent@example.com"
      })
      |> render_submit()

    assert html =~ "No existe un usuario con ese email"
    assert has_element?(view, "#add-member-error")
  end

  # --------------------------------------------------------------------------
  # Remove member
  # --------------------------------------------------------------------------

  test "admin removes a member", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#remove-#{member.id}")

    html = view |> element("#remove-#{member.id}") |> render_click()

    assert html =~ "Miembro eliminado"
    refute has_element?(view, "#remove-#{member.id}")

    refute Repo.get(Tokengate.Accounts.GroupMember, member.id)
  end

  # --------------------------------------------------------------------------
  # Extra model grants (per-member)
  # --------------------------------------------------------------------------

  test "admin toggles an extra model grant on a member", %{conn: conn} do
    %{group: group, member: member, model: model_} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    # Open the member details modal to reach the model picker
    view |> element("#details-#{member.id}") |> render_click()
    assert has_element?(view, "#model-picker-member-#{member.id}-#{model_.id}")

    # Grant the extra model
    html =
      view
      |> element("#model-picker-member-#{member.id}-#{model_.id}")
      |> render_click()

    assert html =~ "Modelos actualizados"

    grant =
      Repo.get_by(
        Tokengate.Providers.GroupMemberExtraModel,
        group_member_id: member.id,
        model_id: model_.id
      )

    assert grant != nil

    # Revoke
    html =
      view
      |> element("#model-picker-member-#{member.id}-#{model_.id}")
      |> render_click()

    assert html =~ "Modelos actualizados"

    refute Repo.get_by(
             Tokengate.Providers.GroupMemberExtraModel,
             group_member_id: member.id,
             model_id: model_.id
           )
  end

  test "admin grants extra model access (no per-model budget)", %{conn: conn} do
    %{group: group, member: member, model: model_} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    # Open the member details modal, then grant via picker toggle
    view |> element("#details-#{member.id}") |> render_click()

    view
    |> element("#model-picker-member-#{member.id}-#{model_.id}")
    |> render_click()

    grant =
      Repo.get_by(
        Tokengate.Providers.GroupMemberExtraModel,
        group_member_id: member.id,
        model_id: model_.id
      )

    assert grant != nil
  end

  # --------------------------------------------------------------------------
  # Empty state
  # --------------------------------------------------------------------------

  test "group with no members shows empty state", %{conn: conn} do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Empty Group #{u}"})

    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, group_url(group))

    assert has_element?(view, "#members-empty")
    assert html =~ "Este perfil de límites no tiene miembros"
  end

  # --------------------------------------------------------------------------
  # API keys y extras: FUERA de esta página
  # --------------------------------------------------------------------------

  # Las keys cuelgan del usuario y los extras de concurrencia/RPM los aporta la
  # sub, así que esta página no debe ofrecer ninguno de esos controles.
  test "the page carries no API key, extra or sticky controls", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    refute has_element?(view, "#replace-key-#{member.id}")
    refute has_element?(view, "#revoke-key-#{member.id}")
    refute has_element?(view, "#edit-overrides-#{member.id}")
    # Limpiar sticky vive a nivel sujeto (usuario / servicio), no por membresía.
    refute has_element?(view, "#clear-sticky-#{member.id}")

    # El modal de alta sólo pide el email.
    view |> element("#new-member-btn") |> render_click()
    refute has_element?(view, "#add-member-form input[name='add_member[extra_concurrency]']")
    refute has_element?(view, "#add-member-form input[name='add_member[extra_rpm]']")

    # El detalle del miembro sigue existiendo (picker de modelos), sin keys.
    view |> element("#cancel-add-member") |> render_click()
    view |> element("#details-#{member.id}") |> render_click()
    assert has_element?(view, "#member-details-#{member.id}")
    refute has_element?(view, "#user-keys-#{member.id}")
    refute has_element?(view, "#user-key-form-#{member.id}")
  end

  # La columna «Límites» muestra el EFECTIVO del miembro (lo que el proxy
  # aplica), no el default crudo del perfil de límites: propio del usuario primero.
  test "the Límites column shows the member's effective limits, badged on own override", %{
    conn: conn
  } do
    %{group: group, owner: owner, member: member} = group_with_member(%{})
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    cell = view |> element("#limits-#{member.id}") |> render()

    # Sin propios: el miembro hereda el default del perfil de límites.
    assert cell =~ "5"
    assert cell =~ "60"
    refute cell =~ "propio"

    {:ok, _owner} =
      Accounts.admin_update_user(owner, %{
        "default_concurrency_limit" => 12,
        "default_rpm_limit" => 144
      })

    {:ok, view, _html} = live(conn, group_url(group))
    cell = view |> element("#limits-#{member.id}") |> render()

    # Con propios: mandan los del usuario y se marcan como override.
    assert cell =~ "12"
    assert cell =~ "144"
    assert cell =~ "propio"
  end
end
