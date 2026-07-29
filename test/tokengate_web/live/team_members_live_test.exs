defmodule TokengateWeb.TeamMembersLiveTest do
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

  # Builds org + team + model_alias. The "owner" user is a member of the team.
  defp team_with_member(opts \\ %{}) do
    u = unique()
    role = Map.get(opts, :team_role, "user")

    {:ok, model_alias} =
      Providers.create_model_alias(%{
        name: "gpt-#{u}",
        display_name: "GPT #{u}",
        market_input_price_per_1m: Decimal.new("10.00"),
        market_output_price_per_1m: Decimal.new("30.00"),
        context_window: 128_000
      })

    {:ok, team} = Accounts.create_team(%{name: "Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{
        user_id: owner.id,
        team_id: team.id,
        team_role: role
      })

    # Provision API key for the member (required for proxy + UI display)
    {:ok, _api_key, _token} = Accounts.replace_api_key(member)
    member = Accounts.get_team_member!(member.id)

    %{
      team: team,
      model_alias: model_alias,
      owner: owner,
      member: member,
      owner_password: "password-secret-#{u}1"
    }
  end

  defp team_url(team), do: "/dashboard/teams/#{team.id}/members"

  # --------------------------------------------------------------------------
  # Access control
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    %{team: team} = team_with_member()
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, team_url(team))
  end

  test "plain user (no manager role) is denied access", %{conn: conn} do
    %{team: team, owner: owner, owner_password: password} = team_with_member(%{team_role: "user"})

    conn = login(conn, owner, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, team_url(team))
  end

  test "manager of a different team is denied", %{conn: conn} do
    # Team A — where the user is a manager
    %{team: team_a, owner: manager, owner_password: password} =
      team_with_member(%{team_role: "manager"})

    # Team B — a different team
    %{team: team_b} = team_with_member()

    conn = login(conn, manager, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, team_url(team_b))

    _ = team_a
  end

  # --------------------------------------------------------------------------
  # Admin access and render
  # --------------------------------------------------------------------------

  test "admin sees members of any team", %{conn: conn} do
    %{team: team, owner: owner} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, team_url(team))

    assert html =~ "Miembros de #{team.name}"
    assert html =~ owner.email
    assert has_element?(view, "#new-member-btn")
  end

  test "manager is redirected from team members to dashboard", %{conn: conn} do
    %{team: team, owner: owner, owner_password: password} =
      team_with_member(%{team_role: "manager"})

    conn = login(conn, owner, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, team_url(team))
  end

  # --------------------------------------------------------------------------
  # Add member
  # --------------------------------------------------------------------------

  test "admin adds a member by email", %{conn: conn} do
    %{team: team} = team_with_member()
    %{user: admin, password: password} = register("admin")

    # Register a separate user to add
    %{user: new_user} = register("user")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    assert view |> element("#new-member-btn") |> render_click()

    html =
      view
      |> form("#add-member-form", %{
        "add_member[email]" => new_user.email,
        "add_member[team_role]" => "user",
        "add_member[extra_monthly_budget_usd]" => "5.00",
        "add_member[extra_concurrency]" => "2",
        "add_member[extra_rpm]" => "100"
      })
      |> render_submit()

    assert html =~ "Miembro añadido"
    assert html =~ new_user.email

    # Verify the team_member was created with overrides
    member =
      Repo.get_by(
        Tokengate.Accounts.TeamMember,
        user_id: new_user.id,
        team_id: team.id
      )

    assert member != nil
    assert member.team_role == "user"
    assert Decimal.equal?(member.extra_monthly_budget_usd || Decimal.new(0), Decimal.new("5.00"))
    assert member.extra_concurrency == 2
    assert member.extra_rpm == 100

    api_key = Repo.get_by(Tokengate.Accounts.ApiKey, team_member_id: member.id)
    assert api_key == nil
  end

  test "add member modal can be cancelled", %{conn: conn} do
    %{team: team} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    assert view |> element("#new-member-btn") |> render_click()
    assert has_element?(view, "#add-member-modal")

    html = view |> element("#cancel-add-member") |> render_click()
    refute html =~ "add-member-modal"
  end

  test "add member with non-existent email shows error", %{conn: conn} do
    %{team: team} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    assert view |> element("#new-member-btn") |> render_click()

    html =
      view
      |> form("#add-member-form", %{
        "add_member[email]" => "nonexistent@example.com",
        "add_member[team_role]" => "user"
      })
      |> render_submit()

    assert html =~ "No existe un usuario con ese email"
    assert has_element?(view, "#add-member-error")
  end

  # --------------------------------------------------------------------------
  # Remove member
  # --------------------------------------------------------------------------

  test "admin removes a member", %{conn: conn} do
    %{team: team, member: member} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    assert has_element?(view, "#remove-#{member.id}")

    html = view |> element("#remove-#{member.id}") |> render_click()

    assert html =~ "Miembro eliminado"
    refute has_element?(view, "#remove-#{member.id}")

    refute Repo.get(Tokengate.Accounts.TeamMember, member.id)
  end

  # --------------------------------------------------------------------------
  # Change role
  # --------------------------------------------------------------------------

  test "admin changes a member's role", %{conn: conn} do
    %{team: team, member: member} = team_with_member(%{team_role: "user"})
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    # The role select should be present
    assert has_element?(view, "#role-select-#{member.id}")

    html =
      view
      |> element("#role-form-#{member.id}")
      |> render_change(%{team_role: "manager"})

    assert html =~ "Rol actualizado"

    updated = Repo.get!(Tokengate.Accounts.TeamMember, member.id)
    assert updated.team_role == "manager"
  end

  # --------------------------------------------------------------------------
  # Overrides (extra_monthly_budget_usd, extra_monthly_budget_usd, extra_concurrency)
  # --------------------------------------------------------------------------

  test "admin edits and saves overrides", %{conn: conn} do
    %{team: team, member: member} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

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

    updated = Repo.get!(Tokengate.Accounts.TeamMember, member.id)
    assert Decimal.equal?(updated.extra_monthly_budget_usd, Decimal.new("5.50"))
    assert updated.extra_concurrency == 3
  end

  test "overrides can be cleared with empty values", %{conn: conn} do
    %{team: team, member: member} = team_with_member()
    %{user: admin, password: password} = register("admin")

    # Pre-set values
    {:ok, _} =
      Accounts.update_team_member(member, %{
        extra_monthly_budget_usd: Decimal.new("10.00"),
        extra_concurrency: 5
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

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

    updated = Repo.get!(Tokengate.Accounts.TeamMember, member.id)
    assert updated.extra_monthly_budget_usd == nil
    assert updated.extra_concurrency == nil
  end

  # --------------------------------------------------------------------------
  # Extra alias grants (per-member)
  # --------------------------------------------------------------------------

  test "admin toggles an extra alias grant on a member", %{conn: conn} do
    %{team: team, member: member, model_alias: alias_} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    # The checkbox should be present and unchecked
    assert has_element?(view, "#extra-alias-#{member.id}-#{alias_.id}")

    # Grant the extra alias
    html =
      view
      |> element("#extra-alias-#{member.id}-#{alias_.id}")
      |> render_click()

    assert html =~ "Aliases actualizados"

    grant =
      Repo.get_by(
        Tokengate.Providers.TeamMemberExtraAlias,
        team_member_id: member.id,
        model_alias_id: alias_.id
      )

    assert grant != nil

    # Revoke
    html =
      view
      |> element("#extra-alias-#{member.id}-#{alias_.id}")
      |> render_click()

    assert html =~ "Aliases actualizados"

    refute Repo.get_by(
             Tokengate.Providers.TeamMemberExtraAlias,
             team_member_id: member.id,
             model_alias_id: alias_.id
           )
  end

  test "admin grants extra alias access (no per-model budget)", %{conn: conn} do
    %{team: team, member: member, model_alias: alias_} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    # Grant the alias via checkbox toggle
    view
    |> element("#extra-alias-#{member.id}-#{alias_.id}")
    |> render_click()

    grant =
      Repo.get_by(
        Tokengate.Providers.TeamMemberExtraAlias,
        team_member_id: member.id,
        model_alias_id: alias_.id
      )

    assert grant != nil
  end

  test "member card shows budget mensual with extra", %{conn: conn} do
    %{team: team, member: member} = team_with_member()

    Accounts.update_team(team, %{monthly_budget_per_user_usd: Decimal.new("10.00")})

    {:ok, _member} =
      Accounts.update_team_member(member, %{extra_monthly_budget_usd: Decimal.new("12.00")})

    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, team_url(team))

    assert html =~ "Budget/mes"
    assert html =~ "$10.00"
    assert html =~ "+$12.00"
  end

  # --------------------------------------------------------------------------
  # Empty state
  # --------------------------------------------------------------------------

  test "team with no members shows empty state", %{conn: conn} do
    u = unique()

    {:ok, team} = Accounts.create_team(%{name: "Empty Team #{u}"})

    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, team_url(team))

    assert has_element?(view, "#members-empty")
    assert html =~ "Este equipo no tiene miembros"
  end

  # --------------------------------------------------------------------------
  # API key management
  # --------------------------------------------------------------------------

  test "admin can regenerate a member's API key", %{conn: conn} do
    %{team: team, member: member} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    html = view |> element("#replace-key-#{member.id}") |> render_click()

    assert html =~ "Clave regenerada"
    assert has_element?(view, "#new-token-#{member.id}")
  end

  test "admin can revoke a member's API key", %{conn: conn} do
    %{team: team, member: member} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, team_url(team))

    assert has_element?(view, "#revoke-key-#{member.id}")

    html = view |> element("#revoke-key-#{member.id}") |> render_click()

    assert html =~ "Clave revocada"
    refute has_element?(view, "#revoke-key-#{member.id}")
  end

  test "member card shows API key status badge", %{conn: conn} do
    %{team: team} = team_with_member()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, _view, html} = live(conn, team_url(team))

    assert html =~ "Activa"
  end
end
