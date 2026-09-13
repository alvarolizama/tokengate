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

  defp group_url(group), do: "/admin/groups/#{group.id}/members"

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
      |> form("#add-member-form", %{
        "add_member[email]" => new_user.email,
        "add_member[extra_monthly_budget_usd]" => "5.00",
        "add_member[extra_concurrency]" => "2",
        "add_member[extra_rpm]" => "100"
      })
      |> render_submit()

    assert html =~ "Miembro añadido"
    assert html =~ new_user.email

    # Verify the group_member was created with overrides
    member =
      Repo.get_by(
        Tokengate.Accounts.GroupMember,
        user_id: new_user.id,
        group_id: group.id
      )

    assert member != nil
    assert Decimal.equal?(member.extra_monthly_budget_usd || Decimal.new(0), Decimal.new("5.00"))
    assert member.extra_concurrency == 2
    assert member.extra_rpm == 100

    api_key = Repo.get_by(Tokengate.Accounts.ApiKey, group_member_id: member.id)
    assert api_key == nil
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
  # Overrides (extra_monthly_budget_usd, extra_concurrency)
  # --------------------------------------------------------------------------

  test "admin edits and saves overrides", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    # Open the overrides form
    view |> element("#edit-overrides-#{member.id}") |> render_click()
    assert has_element?(view, "#override-form-#{member.id}")

    html =
      view
      |> form("#override-form-#{member.id}", %{
        overrides: %{
          extra_monthly_budget_usd: "5.50",
          extra_concurrency: "3"
        }
      })
      |> render_submit()

    assert html =~ "Extras actualizados"

    updated = Repo.get!(Tokengate.Accounts.GroupMember, member.id)
    assert Decimal.equal?(updated.extra_monthly_budget_usd, Decimal.new("5.50"))
    assert updated.extra_concurrency == 3
  end

  test "overrides can be cleared with empty values", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    # Pre-set values
    {:ok, _} =
      Accounts.update_group_member(member, %{
        extra_monthly_budget_usd: Decimal.new("10.00"),
        extra_concurrency: 5
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    view |> element("#edit-overrides-#{member.id}") |> render_click()

    html =
      view
      |> form("#override-form-#{member.id}", %{
        overrides: %{
          extra_monthly_budget_usd: "",
          extra_concurrency: ""
        }
      })
      |> render_submit()

    assert html =~ "Extras actualizados"

    updated = Repo.get!(Tokengate.Accounts.GroupMember, member.id)
    assert updated.extra_monthly_budget_usd == nil
    assert updated.extra_concurrency == nil
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

  test "member card shows budget mensual with extra", %{conn: conn} do
    %{group: group, member: member} = group_with_member()

    Accounts.update_group(group, %{monthly_budget_per_user_usd: Decimal.new("10.00")})

    {:ok, _member} =
      Accounts.update_group_member(member, %{extra_monthly_budget_usd: Decimal.new("12.00")})

    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, group_url(group))

    assert html =~ "Budget/mes"
    assert html =~ "$10.00"
    assert html =~ "+$12.00"
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
    assert html =~ "Este grupo no tiene miembros"
  end

  # --------------------------------------------------------------------------
  # API key management
  # --------------------------------------------------------------------------

  test "admin can regenerate a member's API key", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    html = view |> element("#replace-key-#{member.id}") |> render_click()

    assert html =~ "Clave regenerada"
    assert has_element?(view, "#new-token-#{member.id}")
  end

  test "admin can clear a member's sticky routes", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#clear-sticky-#{member.id}")

    html = view |> element("#clear-sticky-#{member.id}") |> render_click()

    assert html =~ "Sticky routes limpiadas"
  end

  test "admin can revoke a member's API key", %{conn: conn} do
    %{group: group, member: member} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, group_url(group))

    assert has_element?(view, "#revoke-key-#{member.id}")

    html = view |> element("#revoke-key-#{member.id}") |> render_click()

    assert html =~ "Clave revocada"
    refute has_element?(view, "#revoke-key-#{member.id}")
  end

  test "member card shows API key status badge", %{conn: conn} do
    %{group: group} = group_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, group_url(group))

    assert html =~ "Activa"
  end
end
