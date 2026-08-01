defmodule TokengateWeb.UsersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.{Accounts, Logs}

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "users-#{u}@example.com",
        name: "Users #{u}",
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

  ## Auth -------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/dashboard/users")
  end

  test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/dashboard/users")
  end

  ## Admin views ------------------------------------------------------------

  test "admin sees users list with create button", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/dashboard/users")

    assert html =~ "Usuarios"
    assert has_element?(view, "#new-user-btn")
  end

  test "admin sees existing users in the table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _other = register("user")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#users")
    assert has_element?(view, "#new-user-btn")
  end

  test "admin sees spend column with user budget rollup", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(%{
        "name" => "Spend Team #{unique()}",
        "monthly_budget_per_user_usd" => "100.00"
      })

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    {:ok, _log} =
      Logs.log_request(%{
        team_member_id: member.id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new("7.25")
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#spend-#{member_user.id}", "$7.25")
    assert has_element?(view, "#spend-#{admin.id}", "—")
  end

  test "user without credit shows sin crédito badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")

    {:ok, team} =
      Accounts.create_team(%{
        "name" => "Broke Team #{unique()}",
        "monthly_budget_per_user_usd" => "100.00"
      })

    {:ok, member} =
      Accounts.create_team_member(%{"user_id" => member_user.id, "team_id" => team.id})

    {:ok, _log} =
      Logs.log_request(%{
        team_member_id: member.id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new("100.00")
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#spend-#{member_user.id}", "sin crédito")
  end

  ## Create user ------------------------------------------------------------

  test "admin can create a new user without teams", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#new-user-btn") |> render_click()
    assert has_element?(view, "#user-form")

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "newuser@example.com",
          name: "New User",
          password: "valid-password-123",
          global_role: "user"
        }
      })
      |> render_submit()

    assert html =~ "Usuario creado con 0 equipo(s)"
  end

  test "admin can create a new user with multiple teams", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, team_a} = Accounts.create_team(%{name: "Team A #{unique()}"})
    {:ok, team_b} = Accounts.create_team(%{name: "Team B #{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#new-user-btn") |> render_click()
    assert has_element?(view, "#user-form")
    assert has_element?(view, "select[name='user[team_ids][]']")

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "multiteam@example.com",
          name: "Multi Team",
          password: "valid-password-123",
          global_role: "user",
          team_ids: [team_a.id, team_b.id]
        }
      })
      |> render_submit()

    assert html =~ "Usuario creado con 2 equipo(s)"

    # Verify user was created and has 2 memberships with API keys
    user = Accounts.get_user_by_email("multiteam@example.com")
    assert user

    memberships = Accounts.list_team_members_for_user(user.id)
    assert length(memberships) == 2

    for member <- memberships do
      assert member.api_key
      assert member.team_role == "user"
      assert member.status == "active"
    end
  end

  test "admin cannot create user with weak password", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#new-user-btn") |> render_click()

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "weak@example.com",
          name: "Weak",
          password: "short",
          global_role: "user"
        }
      })
      |> render_submit()

    refute html =~ "Usuario creado"
  end

  ## Edit user --------------------------------------------------------------

  test "admin can edit a user's role", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#edit-#{target.id}") |> render_click()
    assert has_element?(view, "#user-edit-form")

    html =
      view
      |> form("#user-edit-form", %{
        user: %{name: target.name, global_role: "admin", status: "active"}
      })
      |> render_submit()

    assert html =~ "Usuario actualizado"

    updated = Accounts.get_user!(target.id)
    assert updated.global_role == "admin"
  end

  ## Suspend/activate -------------------------------------------------------

  test "admin can suspend a user", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    html = view |> element("#status-#{target.id}") |> render_click()
    assert html =~ "Usuario suspendido"

    updated = Accounts.get_user!(target.id)
    assert updated.status == "suspended"
  end

  test "suspended user cannot login with password", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target, password: target_password} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")
    view |> element("#status-#{target.id}") |> render_click()

    # Now try to login as the suspended user
    conn = build_conn()
    conn = post(conn, ~p"/login", %{email: target.email, password: target_password})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "suspendida"
  end

  ## Reset password ---------------------------------------------------------

  test "admin can reset a user's password", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#pwd-#{target.id}") |> render_click()
    assert has_element?(view, "#user-reset-form")

    html =
      view
      |> form("#user-reset-form", %{user: %{password: "new-password-123"}})
      |> render_submit()

    assert html =~ "Contraseña actualizada"

    # Verify the new password works
    conn = build_conn()
    conn = post(conn, ~p"/login", %{email: target.email, password: "new-password-123"})
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Sesión iniciada"
  end

  ## Impersonate --------------------------------------------------------------

  test "admin sees impersonate link for other users but not for self", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#impersonate-#{target.id}")
    refute has_element?(view, "#impersonate-#{admin.id}")
  end

  test "root admin cannot be impersonated", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")

    # Some tests assume a "root" admin exists; the seed script normally creates
    # `admin@tokengate.local`, but tests don't run seeds. Create it on demand.
    {:ok, root} =
      if existing = Accounts.get_user_by_email("admin@tokengate.local") do
        {:ok, existing}
      else
        Accounts.register_user(%{
          email: "admin@tokengate.local",
          name: "Root Admin",
          password: "RootPass123!"
        })
      end

    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    refute has_element?(view, "#impersonate-#{root.id}")
  end

  ## Delete user -------------------------------------------------------------

  alias Tokengate.Logs
  alias Tokengate.Providers

  defp team_with_log do
    u = unique()

    {:ok, team} = Accounts.create_team(%{name: "Del Team #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "del-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_team_member(%{user_id: owner.id, team_id: team.id, team_role: "user"})

    {:ok, _api_key, _token} = Accounts.replace_api_key(member)

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, ma} =
      Providers.create_model_alias(%{
        name: "model-#{u}",
        display_name: "Model #{u}",
        context_window: 128_000
      })

    {:ok, _log} =
      Logs.log_request(%{
        team_member_id: member.id,
        provider_id: provider.id,
        model_alias_id: ma.id,
        model_requested: "model-#{u}",
        model_responded: "model-#{u}",
        agent_type: "api",
        status_code: 200,
        prompt_tokens: 100,
        completion_tokens: 50,
        provider_cost_usd: "0.005",
        latency_ms: 42,
        streaming: false
      })

    %{team: team, owner: owner, member: member}
  end

  test "admin sees delete button for other users", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    assert has_element?(view, "#delete-#{target.id}")
    refute has_element?(view, "#delete-#{admin.id}")
  end

  test "root admin has no delete button", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")

    {:ok, root} =
      if existing = Accounts.get_user_by_email("admin@tokengate.local") do
        {:ok, existing}
      else
        Accounts.register_user(%{
          email: "admin@tokengate.local",
          name: "Root Admin",
          password: "RootPass123!"
        })
      end

    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    refute has_element?(view, "#delete-#{root.id}")
  end

  test "opening delete modal sets target email", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    view |> element("#delete-#{target.id}") |> render_click()

    assert has_element?(view, "#delete-user-modal")
    assert has_element?(view, "#confirm-delete-user")
    assert has_element?(view, "#delete-user-email", target.email)
  end

  test "confirming delete removes user and all associated data", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{team: _team, owner: target, member: member} = team_with_log()

    # Verify data exists before delete
    assert Accounts.get_user!(target.id)
    assert Accounts.list_team_members_for_user(target.id) != []

    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    # Open modal then confirm
    view |> element("#delete-#{target.id}") |> render_click()
    html = view |> element("#confirm-delete-user") |> render_click()

    assert html =~ "Usuario eliminado permanentemente"

    # User is gone
    assert Accounts.get_user(target.id) == nil

    # Team member is gone (cascade)
    refute Tokengate.Repo.get(Tokengate.Accounts.TeamMember, member.id)

    # API key is gone (cascade)
    refute Tokengate.Repo.get(Tokengate.Accounts.ApiKey, member.id)
  end

  test "admin cannot delete self", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/dashboard/users")

    # No delete button for self
    refute has_element?(view, "#delete-#{admin.id}")
  end
end
