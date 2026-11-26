defmodule TokengateWeb.GroupMembersLiveTest do
  use TokengateWeb.ConnCase, async: false
  use Gettext, backend: TokengateWeb.Gettext

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

    expected_title =
      Gettext.with_locale(TokengateWeb.Gettext, "es", fn ->
        gettext("Members of %{name}", name: group.name)
      end)

    assert html =~ expected_title
    assert html =~ owner.email
    assert has_element?(view, "#new-member-btn")
    assert has_element?(view, "#member-search")
    assert has_element?(view, "#back-to-groups[href=\"/budget/profiles\"]")
    assert has_element?(view, "#remove-#{owner_member_id(group, owner)}[data-confirm]")
  end

  defp owner_member_id(group, owner) do
    Repo.get_by!(Tokengate.Accounts.GroupMember, group_id: group.id, user_id: owner.id).id
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

  # --------------------------------------------------------------------------
  # Ids del cliente + stream de miembros (F6)
  # --------------------------------------------------------------------------

  test "a malformed profile id redirects instead of crashing", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/budget/profiles"}}} =
             live(conn, "/budget/profiles/no-es-un-uuid/members")
  end

  test "an unknown profile id redirects instead of crashing", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/budget/profiles"}}} =
             live(conn, "/budget/profiles/#{Ecto.UUID.generate()}/members")
  end

  test "malformed member ids never crash the member handlers", %{conn: conn} do
    %{group: group, member: member, model: model_} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    for {event, params} <- [
          {"remove_member", %{"id" => "no-es-un-uuid"}},
          {"open_details", %{"id" => "no-es-un-uuid"}},
          {"toggle_extra_model", %{"target-id" => "no-es-un-uuid", "model-id" => model_.id}},
          {"set_router_access", %{"id" => "no-es-un-uuid", "state" => "allow"}},
          {"remove_member", %{"id" => Ecto.UUID.generate()}}
        ] do
      html = render_hook(view, event, params)
      assert html =~ "no pertenece a este perfil de límites"
    end

    # La vista sigue viva y el miembro real intacto.
    assert has_element?(view, "#remove-#{member.id}")
    refute has_element?(view, "#member-details-no-es-un-uuid")
  end

  test "a member of another profile cannot be touched from this page", %{conn: conn} do
    %{group: group} = group_with_member()
    %{member: foreign} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    html = render_hook(view, "remove_member", %{"id" => foreign.id})
    assert html =~ "no pertenece a este perfil de límites"
    assert Repo.get(Tokengate.Accounts.GroupMember, foreign.id)

    html = render_hook(view, "open_details", %{"id" => foreign.id})
    assert html =~ "no pertenece a este perfil de límites"
    refute has_element?(view, "#member-details-#{foreign.id}")
  end

  test "members are rendered as a stream with per-row DOM ids", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#members-rows[phx-update='stream']")
    assert has_element?(view, "tr#members-#{member.id}")
  end

  test "3-state model picker denies inherited models in 1 click and revokes own extras cleanly",
       %{conn: conn} do
    %{group: group, member: member, model: extra_model} = group_with_member()
    u = unique()

    {:ok, inherited_model} =
      Providers.create_model(%{name: "inherited-#{u}", context_window: 128_000})

    {:ok, _} = Providers.grant_model_to_group(group.id, inherited_model.id)
    {:ok, _} = Providers.grant_extra_model(member.id, extra_model.id)

    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    view |> element("#details-#{member.id}") |> render_click()

    # Inherited profile model: 1 click denies it without creating an extra row.
    view
    |> element("#model-picker-member-#{member.id}-#{inherited_model.id}")
    |> render_click()

    assert inherited_model.id in Providers.list_denied_model_ids_for_member(member.id)
    refute inherited_model.id in Providers.list_extra_model_ids_for_member(member.id)

    # Clicking again allows it back.
    view
    |> element("#model-picker-member-#{member.id}-#{inherited_model.id}")
    |> render_click()

    refute inherited_model.id in Providers.list_denied_model_ids_for_member(member.id)

    # Own extra model (not inherited): 1 click revokes it without marking denied.
    view
    |> element("#model-picker-member-#{member.id}-#{extra_model.id}")
    |> render_click()

    refute extra_model.id in Providers.list_extra_model_ids_for_member(member.id)
    refute extra_model.id in Providers.list_denied_model_ids_for_member(member.id)
  end

  # --------------------------------------------------------------------------
  # Search, sorting, pagination, and async usage tiers
  # --------------------------------------------------------------------------

  test "search filters members by email or name and sort reorders rows", %{conn: conn} do
    %{group: group, owner: owner1, member: m1} = group_with_member()
    %{user: admin, password: password} = register("admin")
    %{user: owner2} = register("user")

    {:ok, owner2} =
      Accounts.admin_update_user(owner2, %{
        "name" => "Zed Searchable"
      })

    {:ok, m2} = Accounts.create_group_member(%{user_id: owner2.id, group_id: group.id})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#members-#{m1.id}")
    assert has_element?(view, "#members-#{m2.id}")

    view |> element("#search-form") |> render_change(%{"q" => "Zed Searchable"})

    assert has_element?(view, "#members-#{m2.id}")
    refute has_element?(view, "#members-#{m1.id}")

    # Clear search and sort by email desc
    view |> element("#search-form") |> render_change(%{"q" => ""})
    assert has_element?(view, "#members-#{m1.id}")

    html = view |> element("th button[phx-value-field='email']") |> render_click()
    assert html =~ "▼"

    expected_first = if owner1.email > owner2.email, do: m1.id, else: m2.id
    expected_second = if expected_first == m1.id, do: m2.id, else: m1.id

    ids =
      Regex.scan(~r/<tr[^>]+id="members-([^"]+)"/, html)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.filter(&(&1 in [m1.id, m2.id]))

    assert ids == [expected_first, expected_second]
  end

  test "paginates members in DB with 30 per page", %{conn: conn} do
    {:ok, group} = Accounts.create_group(%{name: "Paged Members #{unique()}"})
    %{user: admin, password: password} = register("admin")

    members =
      for i <- 1..31 do
        pad = i |> Integer.to_string() |> String.pad_leading(3, "0")

        user =
          %Tokengate.Accounts.User{}
          |> Ecto.Changeset.change(%{
            email: "member-#{pad}-#{unique()}@example.com",
            name: "Member #{pad}",
            password_hash: "not-a-real-hash",
            global_role: "user"
          })
          |> Repo.insert!()

        {:ok, m} = Accounts.create_group_member(%{user_id: user.id, group_id: group.id})
        m
      end

    first = hd(members)
    last = List.last(members)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#members-pagination")
    assert has_element?(view, "#members-pagination-range", "1–30 de 31")
    assert has_element?(view, "#members-#{first.id}")
    refute has_element?(view, "#members-#{last.id}")

    view |> element("#members-pagination-page-2") |> render_click()

    assert has_element?(view, "#members-pagination-range", "31–31 de 31")
    assert has_element?(view, "#members-#{last.id}")
    refute has_element?(view, "#members-#{first.id}")
  end

  test "loads 30-day usage tiers asynchronously via start_async", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        group_member_id: member.id,
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("12.00"),
        prompt_tokens: 1000,
        completion_tokens: 500,
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    html = render_async(view)
    assert html =~ "Alto"
  end

  test "group summary card shows cap and real total spend across search/pagination, and member rows show budget_cell and top-up shortcut",
       %{conn: conn} do
    {:ok, group} =
      Accounts.create_group(%{
        name: "Budgeted Profile #{unique()}",
        monthly_spend_limit_usd: "50.00"
      })

    %{user: admin, password: password} = register("admin")
    %{user: u1} = register("user")
    %{user: u2} = register("user")
    {:ok, m1} = Accounts.create_group_member(%{user_id: u1.id, group_id: group.id})
    {:ok, m2} = Accounts.create_group_member(%{user_id: u2.id, group_id: group.id})

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        group_member_id: m1.id,
        user_id: u1.id,
        subject_type: "user",
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("10.00"),
        latency_ms: 100
      })

    {:ok, _} =
      Tokengate.Logs.log_request(%{
        group_member_id: m2.id,
        user_id: u2.id,
        subject_type: "user",
        model_requested: "gpt-4o",
        provider_cost_usd: Decimal.new("15.00"),
        latency_ms: 100
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#group-config-cap", "$50.00")
    assert has_element?(view, "#group-config", "$25.00")
    assert has_element?(view, "#group-config-stats-link[href=\"/stats/profiles/#{group.id}\"]")
    assert has_element?(view, "#credit-#{m1.id}", "OK")

    assert has_element?(
             view,
             "#topup-#{m1.id}[href=\"/budget/topups?owner_kind=user&owner_id=#{u1.id}\"]"
           )

    # Even when searching for u1 only, #group-config keeps the profile's full $25.00 spend.
    view |> element("#search-form") |> render_change(%{"q" => u1.email})
    assert has_element?(view, "#members-#{m1.id}")
    refute has_element?(view, "#members-#{m2.id}")
    assert has_element?(view, "#group-config", "$25.00")
  end

  # --------------------------------------------------------------------------
  # SmartRouter access — tri-estado heredar/permitir/negar
  # --------------------------------------------------------------------------

  test "el modal del miembro persiste el tri-estado, audita y refresca el estado efectivo",
       %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    # El perfil (false por default) se hereda: la fila lo dice y no hay override.
    assert has_element?(view, "#router-state-#{member.id}", "Heredado")

    view |> element("#details-#{member.id}") |> render_click()
    assert has_element?(view, "#router-access-#{member.id}")
    assert has_element?(view, "#router-effective-#{member.id}", "denegado")

    # Permitir: override propio del miembro.
    view |> element("#router-access-allow-#{member.id}") |> render_click()

    assert Accounts.get_group_member!(member.id).router_enabled == true
    assert has_element?(view, "#router-effective-#{member.id}", "permitido")
    assert has_element?(view, "#router-state-#{member.id}", "Permitido")

    assert [allow_audit] =
             Tokengate.Auditing.list_audit_logs(%{
               action: "group_member.router_access_change",
               entity_id: member.id
             })

    assert allow_audit.changes["router_enabled"] == true
    assert allow_audit.changes["effective"] == true

    # Negar: el override gana sobre el perfil.
    view |> element("#router-access-deny-#{member.id}") |> render_click()

    assert Accounts.get_group_member!(member.id).router_enabled == false
    assert has_element?(view, "#router-effective-#{member.id}", "denegado")
    assert has_element?(view, "#router-state-#{member.id}", "Denegado")

    # Heredar: vuelve a nil y el efectivo lo decide el perfil.
    view |> element("#router-access-inherit-#{member.id}") |> render_click()

    assert Accounts.get_group_member!(member.id).router_enabled == nil
    assert has_element?(view, "#router-effective-#{member.id}", "del perfil de límites")
    assert has_element?(view, "#router-state-#{member.id}", "Heredado")
  end

  test "un miembro que hereda sigue al perfil cuando el perfil permite el router", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    {:ok, group} = Accounts.update_group(group, %{router_enabled: true})
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#router-state-#{member.id}", "Heredado")
    assert has_element?(view, "#router-state-#{member.id}", "efectivo: permitido")

    # Negar en el miembro apaga el efectivo aunque el perfil lo permita.
    render_hook(view, "set_router_access", %{"id" => member.id, "state" => "deny"})

    assert has_element?(view, "#router-state-#{member.id}", "Denegado")
    assert has_element?(view, "#router-state-#{member.id}", "efectivo: denegado")
    assert Accounts.get_group_member!(member.id).router_enabled == false
  end
end
