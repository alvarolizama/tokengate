defmodule TokengateWeb.UsersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Credits, Logs}
  alias Tokengate.Accounts.User
  alias Tokengate.Repo

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

  # Volumen para los tests de paginado. Inserta directo (sin Bcrypt): solo
  # hacen falta filas, no credenciales válidas. Nombres "Paginado NN" para que
  # el orden por nombre (el default de la tabla) sea determinista.
  defp bulk_users(count) do
    for i <- 1..count do
      %User{}
      |> Ecto.Changeset.change(%{
        email: "pag-#{unique()}-#{i}@example.com",
        name: "Paginado #{String.pad_leading(Integer.to_string(i), 2, "0")}",
        password_hash: "not-a-real-hash",
        global_role: "user"
      })
      |> Repo.insert!()
    end
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
    # Sin requests el gasto es $0.00 (ausencia en el agregado = no gastó), no «—»:
    # «—» se leía como «no se calculó».
    assert has_element?(view, "#spend-#{admin.id}", "$0.00")
    assert has_element?(view, "#total-spend-#{admin.id}", "$0.00")
  end

  test "un usuario sin requests muestra $0.00 en las dos columnas de gasto", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_without_logs} = register("user")
    %{user: without_membership} = register("user")

    {:ok, group} = Accounts.create_group(%{"name" => "Sin logs #{unique()}"})

    {:ok, _} =
      Accounts.create_group_member(%{
        "user_id" => member_without_logs.id,
        "group_id" => group.id
      })

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    # Con membresía y sin logs: el agregado del mes trae la fila (0), el total
    # histórico no — los dos tienen que leerse igual.
    assert has_element?(view, "#spend-#{member_without_logs.id}", "$0.00")
    assert has_element?(view, "#total-spend-#{member_without_logs.id}", "$0.00")

    # Sin membresía no aparece en ningún agregado: tampoco es «—».
    assert has_element?(view, "#spend-#{without_membership.id}", "$0.00")
    assert has_element?(view, "#total-spend-#{without_membership.id}", "$0.00")
  end

  describe "credit column" do
    test "shows consumed/total limit for a user in a group with a monthly limit", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: member_user} = register("user")

      {:ok, group} =
        Accounts.create_group(%{
          name: "Credit Group #{unique()}",
          monthly_spend_limit_usd: "100.00"
        })

      {:ok, member} =
        Accounts.create_group_member(%{"user_id" => member_user.id, "group_id" => group.id})

      # $30 consumidos del techo: la celda lee consumido / techo (misma
      # lectura que /stats y el dashboard), no el remanente.
      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("30.00")
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      assert has_element?(view, "#credit-#{member_user.id}", "30.0000 / 100.0000")
    end

    test "shows Ilimitado badge for users marked unlimited", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: plain} = register("user")

      {:ok, group} =
        Accounts.create_group(%{name: "Unlimited #{unique()}", unlimited_spend: true})

      {:ok, _} =
        Accounts.create_group_member(%{"user_id" => plain.id, "group_id" => group.id})

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      assert has_element?(view, "#credit-#{plain.id}", "Ilimitado")
    end

    test "un techo propio sin membresía muestra su gasto real, no ceros", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      # Sin membresía no hay clave API, así que este estado solo llega por
      # datos heredados (backfill). El `request_logs` necesita un
      # `group_member_id` (lo exige el changeset para `subject_type: "user"`) y
      # aquí se usa el de otra membresía: el gasto del sujeto se agrega por la
      # columna `user_id`, que es la que mira la columna de crédito.
      %{user: orphan} = register("user")

      {:ok, orphan} =
        Accounts.update_user(orphan, %{"monthly_spend_limit_usd" => "100.00"})

      {:ok, group} = Accounts.create_group(%{name: "Orphanholder #{unique()}"})

      {:ok, elsewhere} =
        Accounts.create_group_member(%{"user_id" => admin.id, "group_id" => group.id})

      {:ok, _} =
        Logs.log_request(%{
          group_member_id: elsewhere.id,
          user_id: orphan.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("30.00")
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      assert Accounts.list_group_members_for_user(orphan.id) == []
      assert has_element?(view, "#credit-#{orphan.id}", "30.0000 / 100.0000")
    end

    test "credit column is sortable (desc default: most consumed first)", %{conn: conn} do
      %{user: admin, password: password} = register("admin")

      %{user: rich} = register("user")
      %{user: poor} = register("user")

      {:ok, group_rich} =
        Accounts.create_group(%{
          name: "Rich #{unique()}",
          monthly_spend_limit_usd: "200.00"
        })

      {:ok, group_poor} =
        Accounts.create_group(%{name: "Poor #{unique()}", monthly_spend_limit_usd: "50.00"})

      {:ok, member_rich} =
        Accounts.create_group_member(%{"user_id" => rich.id, "group_id" => group_rich.id})

      {:ok, poor_member} =
        Accounts.create_group_member(%{"user_id" => poor.id, "group_id" => group_poor.id})

      # El rico consume poco de un techo grande (10/200); el pobre consume casi
      # todo el suyo (40/50). El orden es por CONSUMO, así que el pobre va
      # primero — el remanente (190 vs 10) ordenaría al revés.
      {:ok, _} =
        Logs.log_request(%{
          group_member_id: member_rich.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("10.00")
        })

      {:ok, _} =
        Logs.log_request(%{
          group_member_id: poor_member.id,
          model_requested: "gpt-4",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          provider_cost_usd: Decimal.new("40.00")
        })

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      # El default de la tabla es por nombre (rich se registró primero), así
      # que hay que pedir el orden por crédito: desc = más consumo primero.
      html = view |> element("#sort-credit") |> render_click()

      rich_first? = fn html ->
        Regex.scan(~r/id="user-([0-9a-f-]+)"/, html)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.filter(&(&1 in [to_string(rich.id), to_string(poor.id)]))
      end

      assert rich_first?.(html) == [to_string(poor.id), to_string(rich.id)]
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

  test "a user with a sub appears once, with their sub badge", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    %{user: member_user} = register("user")

    {:ok, sub} = Accounts.create_group(%{name: "Multi A #{unique()}"})
    {:ok, _} = Accounts.create_group_member(%{user_id: member_user.id, group_id: sub.id})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    # Una sola fila por usuario, con su sub mensual. (Un usuario no puede
    # tener dos: la DB lo impide con un índice único sobre user_id.)
    assert has_element?(view, "tr#user-#{member_user.id}", sub.name)
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

  test "admin can create a new user without a sub", %{conn: conn} do
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

    assert html =~ "Usuario creado"
  end

  test "admin can create a new user with a sub", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, sub} = Accounts.create_group(%{name: "Group A #{unique()}"})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    view |> element("#new-user-btn") |> render_click()
    assert has_element?(view, "#user-form")

    # Select único: un usuario pertenece a UNA sola sub mensual.
    assert has_element?(view, "select[name='user[sub_id]']")
    refute has_element?(view, "select[name='user[group_ids][]']")

    html =
      view
      |> form("#user-form", %{
        user: %{
          email: "multigroup@example.com",
          name: "Multi Group",
          password: "valid-password-123",
          global_role: "user",
          sub_id: sub.id
        }
      })
      |> render_submit()

    assert html =~ "Usuario creado"

    # Verify user was created and has 1 membership with an API key
    user = Accounts.get_user_by_email("multigroup@example.com")
    assert user

    memberships = Accounts.list_group_members_for_user(user.id)
    assert length(memberships) == 1

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

  test "admin can set a user's own concurrency/RPM limits from the edit form", %{conn: conn} do
    %{user: admin, password: admin_password} = register("admin")
    %{user: target} = register("user")
    conn = login(conn, admin, admin_password)
    {:ok, view, _html} = live(conn, ~p"/access/users")

    view |> element("#edit-#{target.id}") |> render_click()

    # Los límites propios del usuario son el primer eslabón de la regla única
    # `propio || contenedor || default`: el form de edición los expone.
    assert has_element?(view, "#user-edit-form input[name='user[default_concurrency_limit]']")
    assert has_element?(view, "#user-edit-form input[name='user[default_rpm_limit]']")

    html =
      view
      |> form("#user-edit-form", %{
        user: %{
          name: target.name,
          global_role: "user",
          status: "active",
          default_concurrency_limit: "12",
          default_rpm_limit: "144"
        }
      })
      |> render_submit()

    assert html =~ "Usuario actualizado"

    updated = Accounts.get_user!(target.id)
    assert updated.default_concurrency_limit == 12
    assert updated.default_rpm_limit == 144

    # El form los vuelve a leer del usuario (no son un input de un solo uso).
    view |> element("#edit-#{target.id}") |> render_click()

    assert view
           |> element("#user-edit-form input[name='user[default_concurrency_limit]']")
           |> render() =~ ~s(value="12")
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
    # uniform ("Invalid credentials.") so the login endpoint can't be
    # used to enumerate suspended accounts — the user is still rejected.
    conn = build_conn()
    conn = post(conn, ~p"/login", %{email: target.email, password: target_password})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid credentials"
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
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed in"
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

  ## Paginado ---------------------------------------------------------------

  describe "paginated table" do
    test "page 1 shows 25 users and page 2 the rest", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      users = bulk_users(30)
      first = Enum.at(users, 0)
      last = Enum.at(users, 29)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      # admin + 30 → 31 filas en total
      assert has_element?(view, "#users-pagination")
      assert has_element?(view, "#users-pagination-range", "1–25 de 31")
      # Con más filas que la página más pequeña, el selector de tamaño sí pinta.
      assert has_element?(view, "#users-pagination-per-page")
      assert has_element?(view, "#user-#{first.id}")
      refute has_element?(view, "#user-#{last.id}")
      assert has_element?(view, "#users-pagination-prev[disabled]")

      html = view |> element("#users-pagination-next") |> render_click()

      assert html =~ "26–31 de 31"
      assert has_element?(view, "#users-pagination-page-2[aria-current=page]")
      assert has_element?(view, "#user-#{last.id}")
      refute has_element?(view, "#user-#{first.id}")
      assert has_element?(view, "#users-pagination-next[disabled]")

      view |> element("#users-pagination-prev") |> render_click()

      assert has_element?(view, "#users-pagination-range", "1–25 de 31")
      assert has_element?(view, "#user-#{first.id}")
    end

    test "changing page size re-paginates from page 1", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      _users = bulk_users(30)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#users-pagination-next") |> render_click()
      assert has_element?(view, "#users-pagination-range", "26–31 de 31")

      html =
        view
        |> element("#users-pagination-per-page")
        |> render_change(%{"per_page" => "100"})

      assert html =~ "1–31 de 31"
      refute has_element?(view, "#users-pagination-page-2")
      assert has_element?(view, "#users-pagination-next[disabled]")
      assert has_element?(view, "#users-pagination-prev[disabled]")
    end

    test "el selector de tamaño sólo se pinta cuando la tabla no cabe en una página",
         %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      _users = bulk_users(3)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      # admin + 3 → 4 filas: caben en la página más pequeña (25), así que el
      # selector no puede cambiar nada y se leía como un control roto.
      assert has_element?(view, "#users-pagination-range", "1–4 de 4")
      refute has_element?(view, "#users-pagination-per-page")
      assert has_element?(view, "#users-pagination-prev[disabled]")
      assert has_element?(view, "#users-pagination-next[disabled]")
    end

    test "searching brings the table back to page 1", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      users = bulk_users(30)
      last = Enum.at(users, 29)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#users-pagination-next") |> render_click()
      assert has_element?(view, "#user-#{last.id}")

      view |> element("#search-form") |> render_change(%{"q" => "Paginado 30"})

      assert has_element?(view, "#users-pagination-range", "1–1 de 1")
      assert has_element?(view, "#user-#{last.id}")
      refute has_element?(view, "#users-pagination-page-2")
    end

    test "sorting brings the table back to page 1", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      _users = bulk_users(30)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#users-pagination-next") |> render_click()
      assert has_element?(view, "#users-pagination-range", "26–31 de 31")

      view |> element("#sort-name") |> render_click()

      assert has_element?(view, "#users-pagination-range", "1–25 de 31")
    end
  end

  ## API keys (N keys con label) --------------------------------------------

  describe "user API keys" do
    defp create_key(user, label) do
      {_token, key_hash, key_prefix} = Accounts.generate_api_key_material()

      {:ok, key} =
        Accounts.create_api_key(%{
          "subject_type" => "member",
          "user_id" => user.id,
          "key_hash" => key_hash,
          "key_prefix" => key_prefix,
          "label" => label
        })

      key
    end

    test "shows all keys of a user with their labels", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: target} = register("user")
      k1 = create_key(target, "laptop")
      k2 = create_key(target, "server")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#keys-#{target.id}") |> render_click()

      assert has_element?(view, "#user-keys-modal")
      assert has_element?(view, "#key-#{k1.id}", "laptop")
      assert has_element?(view, "#key-#{k2.id}", "server")
      assert has_element?(view, "#revoke-key-#{k1.id}")
      assert has_element?(view, "#revoke-key-#{k2.id}")
    end

    test "la columna Claves cuenta las keys activas del usuario", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: target} = register("user")
      _k1 = create_key(target, "laptop")
      _k2 = create_key(target, "server")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      assert has_element?(view, "#keys-#{target.id}", "2 claves")
    end

    test "revoking one key does not affect the other", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: target} = register("user")
      k1 = create_key(target, "revocar")
      k2 = create_key(target, "seguir")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#keys-#{target.id}") |> render_click()
      assert has_element?(view, "#key-#{k1.id}")
      assert has_element?(view, "#key-#{k2.id}")

      view |> element("#revoke-key-#{k1.id}") |> render_click()

      # La revocada sale de la lista (la lista solo trae activas)…
      refute has_element?(view, "#key-#{k1.id}")
      # …y la otra sigue viva.
      assert has_element?(view, "#key-#{k2.id}", "seguir")

      assert Accounts.get_api_key(k1.id).status == "revoked"
      assert Accounts.get_api_key(k2.id).status == "active"
      assert Enum.map(Accounts.list_api_keys_for_user(target.id), & &1.id) == [k2.id]
    end

    test "creating a key with a label adds it alongside the existing ones", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: target} = register("user")
      k1 = create_key(target, "ci")

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#keys-#{target.id}") |> render_click()
      assert has_element?(view, "#key-#{k1.id}", "ci")

      html =
        view
        |> form("#new-key-form", %{key: %{label: "nueva"}})
        |> render_submit()

      assert html =~ "Clave creada"
      labels = Accounts.list_api_keys_for_user(target.id) |> Enum.map(& &1.label) |> Enum.sort()
      assert labels == ["ci", "nueva"]
      assert has_element?(view, "#new-key-token")
    end

    # La stickiness es DEL USUARIO (todas sus keys), no de una key ni de una
    # membresía: la acción vive en este modal y limpia las N keys de golpe.
    test "clearing sticky routes drops the stickies of ALL the user's keys", %{conn: conn} do
      %{user: admin, password: password} = register("admin")
      %{user: target} = register("user")
      _k1 = create_key(target, "laptop")
      _k2 = create_key(target, "server")

      hashes = Accounts.list_api_keys_for_user(target.id) |> Enum.map(& &1.key_hash)
      other_hash = "hash-de-otro-usuario"

      for hash <- hashes ++ [other_hash] do
        Tokengate.Routing.StickyTracker.put(hash, "model-1", "ap-1")
      end

      _ = :sys.get_state(Tokengate.Routing.StickyTracker)

      conn = login(conn, admin, password)
      {:ok, view, _html} = live(conn, ~p"/access/users")

      view |> element("#keys-#{target.id}") |> render_click()
      assert has_element?(view, "#clear-user-sticky-btn")

      html = view |> element("#clear-user-sticky-btn") |> render_click()

      assert html =~ "Sticky routes limpiadas"

      for hash <- hashes do
        assert Tokengate.Routing.StickyTracker.get(hash, "model-1") == nil
      end

      # La de otro usuario sobrevive.
      assert Tokengate.Routing.StickyTracker.get(other_hash, "model-1") == "ap-1"
    end
  end
end
