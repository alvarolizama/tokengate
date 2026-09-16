defmodule TokengateWeb.UsersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Credits, Logs}

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
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/access/users")
  end

  test "regular user is redirected to /dashboard (admin-only)", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/access/users")
  end

  ## Admin views ------------------------------------------------------------

  test "admin sees users list with create button", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, ~p"/access/users")

    assert html =~ "Usuarios"
    assert has_element?(view, "#new-user-btn")
  end

  test "admin sees existing users in the table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    _other = register("user")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    assert has_element?(view, "#users")
    assert has_element?(view, "#new-user-btn")
  end

  test "admin sees spend column with user budget rollup", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")

    {:ok, group} =
      Accounts.create_group(%{
        "name" => "Spend Group #{unique()}",
        "monthly_budget_per_user_usd" => "100.00"
      })

    {:ok, member} =
      Accounts.create_group_member(%{"user_id" => member_user.id, "group_id" => group.id})

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        model_requested: "gpt-4",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_cost_usd: Decimal.new("7.25")
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    assert has_element?(view, "#spend-#{member_user.id}", "$7.25")
    assert has_element?(view, "#spend-#{admin.id}", "—")
  end

  describe "credit column" do
    test "shows remaining/total credit for a user with grants", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: member_user} = register("user")

      {:ok, group} = Accounts.create_group(%{name: "Credit Group #{unique()}"})

      {:ok, member} =
        Accounts.create_group_member(%{"user_id" => member_user.id, "group_id" => group.id})

      {:ok, sub} =
        Credits.create_subscription(%{
          "units" => 100,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      {:ok, _} = Credits.set_group_default(group, sub)

      # $30 consumidos del grant (sub, usuario) del ciclo.
      {:ok, _} =
        Tokengate.Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("30.00"),
          credit_subscription_id: sub.id
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      assert has_element?(view, "#credit-#{member_user.id}", "$70.00")
      assert has_element?(view, "#credit-#{member_user.id}", "$100.00")
    end

    test "shows Ilimitado badge for users without subscriptions (tier 3)", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: plain} = register("user")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      assert has_element?(view, "#credit-#{plain.id}", "Ilimitado")
    end

    test "credit column is sortable (desc default: most remaining first)", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      %{user: rich} = register("user")
      %{user: poor} = register("user")

      {:ok, group_rich} = Accounts.create_group(%{name: "Rich #{unique()}"})
      {:ok, group_poor} = Accounts.create_group(%{name: "Poor #{unique()}"})

      {:ok, sub_rich} =
        Credits.create_subscription(%{
          "units" => 200,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      {:ok, sub_poor} =
        Credits.create_subscription(%{
          "units" => 50,
          "recurrence" => "monthly",
          "reset_day" => 1
        })

      {:ok, _} = Credits.set_group_default(group_rich, sub_rich)
      {:ok, _} = Credits.set_group_default(group_poor, sub_poor)

      {:ok, _} =
        Accounts.create_group_member(%{"user_id" => rich.id, "group_id" => group_rich.id})

      {:ok, _} =
        Accounts.create_group_member(%{"user_id" => poor.id, "group_id" => group_poor.id})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      # Desc default → el de mayor saldo primero.
      html = render(view)
      assert html =~ "Crédito"

      rich_first? = fn html ->
        Regex.scan(~r/id="user-([0-9a-f-]+)"/, html)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.filter(&(&1 in [to_string(rich.id), to_string(poor.id)]))
      end

      assert rich_first?.(html) == [to_string(rich.id), to_string(poor.id)]
    end
  end

  ## Flat listing + sorting ----------------------------------------------------

  test "users are listed flat (no group group headers), alphabetical by name", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{group: group, owner: _owner} = group_with_log()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    # No group header rows — the table is a flat alphabetical list.
    refute has_element?(view, "tr#group-#{group.id}")
    refute has_element?(view, "tr#group-none", "Sin grupo")
    # The admin (no group) still appears as a regular row.
    assert has_element?(view, "tr#user-#{admin.id}")
  end

  test "a user with two groups appears once, with all their group badges", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: multi} = register("user")

    {:ok, group_a} = Accounts.create_group(%{name: "Multi A #{unique()}"})
    {:ok, group_b} = Accounts.create_group(%{name: "Multi B #{unique()}"})
    {:ok, _} = Accounts.create_group_member(%{user_id: multi.id, group_id: group_a.id})
    {:ok, _} = Accounts.create_group_member(%{user_id: multi.id, group_id: group_b.id})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    # Single row for the user, showing both group badges.
    assert has_element?(view, "tr#user-#{multi.id}", group_a.name)
    assert has_element?(view, "tr#user-#{multi.id}", group_b.name)
  end

  test "clicking the Usuario sort header re-orders rows alphabetically", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, group} = Accounts.create_group(%{name: "Sort Group #{unique()}"})

    {:ok, zeta} =
      Accounts.register_user(%{
        email: "zeta-#{unique()}@example.com",
        name: "Zeta",
        password: "password-secret-z1",
        global_role: "user"
      })

    {:ok, alpha} =
      Accounts.register_user(%{
        email: "alpha-#{unique()}@example.com",
        name: "Alpha",
        password: "password-secret-a1",
        global_role: "user"
      })

    {:ok, _} = Accounts.create_group_member(%{user_id: zeta.id, group_id: group.id})
    {:ok, _} = Accounts.create_group_member(%{user_id: alpha.id, group_id: group.id})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    row_order = fn view ->
      Regex.scan(~r/<tr[^>]+id="(user-[^"]+)"/, render(view))
      |> Enum.map(fn [_full, id] -> id end)
      |> Enum.filter(&(&1 in ["user-#{alpha.id}", "user-#{zeta.id}"]))
    end

    # Default sort is name asc → Alpha before Zeta.
    assert row_order.(view) == ["user-#{alpha.id}", "user-#{zeta.id}"]

    # Toggle to desc → Zeta first.
    view |> element("#sort-name") |> render_click()
    assert row_order.(view) == ["user-#{zeta.id}", "user-#{alpha.id}"]

    # Toggle back to asc.
    view |> element("#sort-name") |> render_click()
    assert row_order.(view) == ["user-#{alpha.id}", "user-#{zeta.id}"]
  end

  ## Create user ------------------------------------------------------------

  test "admin can create a new user without groups", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

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

    assert html =~ "Usuario creado con 0 grupo(s)"
  end

  test "admin can create a new user with multiple groups", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, group_a} = Accounts.create_group(%{name: "Group A #{unique()}"})
    {:ok, group_b} = Accounts.create_group(%{name: "Group B #{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    view |> element("#new-user-btn") |> render_click()
    assert has_element?(view, "#user-form")
    assert has_element?(view, "select[name='user[group_ids][]']")

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "multigroup@example.com",
          name: "Multi Group",
          password: "valid-password-123",
          global_role: "user",
          group_ids: [group_a.id, group_b.id]
        }
      })
      |> render_submit()

    assert html =~ "Usuario creado con 2 grupo(s)"

    # Verify user was created and has 2 memberships with API keys
    user = Accounts.get_user_by_email("multigroup@example.com")
    assert user

    memberships = Accounts.list_group_members_for_user(user.id)
    assert length(memberships) == 2

    for member <- memberships do
      assert member.api_key
      assert member.status == "active"
    end
  end

  test "admin cannot create user with weak password", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

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
    {:ok, view, _html} = live(conn, ~p"/access/users")

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
    {:ok, view, _html} = live(conn, ~p"/access/users")

    html = view |> element("#status-#{target.id}") |> render_click()
    assert html =~ "Usuario suspendido"

    updated = Accounts.get_user!(target.id)
    assert updated.status == "suspended"
  end

  test "suspended user cannot login with password", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target, password: target_password} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")
    view |> element("#status-#{target.id}") |> render_click()

    # Now try to login as the suspended user. The flash is deliberately
    # uniform ("Credenciales inválidas.") so the login endpoint can't be
    # used to enumerate suspended accounts — the user is still rejected.
    conn = build_conn()
    conn = post(conn, ~p"/login", %{email: target.email, password: target_password})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Credenciales inválidas"
    refute get_session(conn, :user_id)
  end

  ## Reset password ---------------------------------------------------------

  test "admin can reset a user's password", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

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
    {:ok, view, _html} = live(conn, ~p"/access/users")

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
    {:ok, view, _html} = live(conn, ~p"/access/users")

    refute has_element?(view, "#impersonate-#{root.id}")
  end

  ## Delete user -------------------------------------------------------------
  alias Tokengate.Logs
  alias Tokengate.Providers

  defp group_with_log do
    u = unique()

    {:ok, group} = Accounts.create_group(%{name: "Del Group #{u}"})

    {:ok, owner} =
      Accounts.register_user(%{
        email: "del-owner-#{u}@example.com",
        name: "Owner #{u}",
        password: "password-secret-#{u}1"
      })

    {:ok, member} =
      Accounts.create_group_member(%{user_id: owner.id, group_id: group.id})

    {:ok, _api_key, _token} = Accounts.replace_api_key(member)

    {:ok, provider} =
      Providers.create_provider(%{name: "Prov #{u}", base_url: "http://localhost:1"})

    {:ok, ma} =
      Providers.create_model(%{
        name: "model-#{u}",
        context_window: 128_000
      })

    {:ok, _log} =
      Logs.log_request(%{
        group_member_id: member.id,
        provider_id: provider.id,
        model_id: ma.id,
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

    %{group: group, owner: owner, member: member}
  end

  test "admin sees delete button for other users", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

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
    {:ok, view, _html} = live(conn, ~p"/access/users")

    refute has_element?(view, "#delete-#{root.id}")
  end

  test "opening delete modal sets target email", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    view |> element("#delete-#{target.id}") |> render_click()

    assert has_element?(view, "#delete-user-modal")
    assert has_element?(view, "#confirm-delete-user")
    assert has_element?(view, "#delete-user-email", target.email)
  end

  test "confirming delete removes user and all associated data", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{group: _group, owner: target, member: member} = group_with_log()

    # Verify data exists before delete
    assert Accounts.get_user!(target.id)
    assert Accounts.list_group_members_for_user(target.id) != []

    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    # Open modal then confirm
    view |> element("#delete-#{target.id}") |> render_click()
    html = view |> element("#confirm-delete-user") |> render_click()

    assert html =~ "Usuario eliminado permanentemente"

    # User is gone
    assert Accounts.get_user(target.id) == nil

    # Group member is gone (cascade)
    refute Tokengate.Repo.get(Tokengate.Accounts.GroupMember, member.id)

    # API key is gone (cascade)
    refute Tokengate.Repo.get(Tokengate.Accounts.ApiKey, member.id)
  end

  test "admin cannot delete self", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    # No delete button for self
    refute has_element?(view, "#delete-#{admin.id}")
  end
end
