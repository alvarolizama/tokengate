defmodule TokengateWeb.ServiceMembersLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.Accounts
  alias Tokengate.Accounts.User
  alias Tokengate.Repo

  defp unique, do: System.unique_integer([:positive])

  defp register(role, attrs \\ %{}) do
    u = unique()

    base = %{
      email: "svc-members-#{u}@example.com",
      name: "User #{u}",
      password: "password-secret-#{u}1",
      global_role: role
    }

    {:ok, user} = Accounts.register_user(Map.merge(base, attrs))
    {:ok, user} = Accounts.update_user_locale(user, "es")

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, user, password) do
    conn
    |> post(~p"/login", %{email: user.email, password: password})
    |> recycle()
  end

  defp service_fixture(attrs \\ %{}) do
    {:ok, service} =
      Accounts.create_service(
        Map.merge(
          %{
            name: "Service #{unique()}",
            monthly_spend_limit_usd: "100.00",
            concurrency_limit: 5,
            rpm_limit: 60
          },
          attrs
        )
      )

    service
  end

  defp members_url(service), do: "/access/services/#{service.id}/members"

  # --------------------------------------------------------------------------
  # Access control & invalid IDs
  # --------------------------------------------------------------------------

  test "unauthenticated visitors are redirected to /login", %{conn: conn} do
    service = service_fixture()
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, members_url(service))
  end

  test "non-admin user is redirected to /dashboard", %{conn: conn} do
    service = service_fixture()
    %{user: user, password: password} = register("user")

    conn = login(conn, user, password)
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, members_url(service))
  end

  test "invalid UUID redirects to /access/services with flash", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/access/services", flash: %{"error" => _}}}} =
             live(conn, "/access/services/not-a-uuid/members")
  end

  test "unknown service UUID redirects to /access/services with flash", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    conn = login(conn, admin, password)

    assert {:error, {:redirect, %{to: "/access/services", flash: %{"error" => _}}}} =
             live(conn, "/access/services/#{Ecto.UUID.generate()}/members")
  end

  # --------------------------------------------------------------------------
  # Mount, empty state, and header controls
  # --------------------------------------------------------------------------

  test "admin sees header controls and empty state when no supervisors", %{conn: conn} do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, html} = live(conn, members_url(service))

    assert html =~ service.name
    assert has_element?(view, "#service-member-search")
    assert has_element?(view, "#new-member-btn")
    assert has_element?(view, "#back-to-services[href=\"/access/services\"]")
    assert has_element?(view, "#service-members-empty")
  end

  # --------------------------------------------------------------------------
  # Search and sort
  # --------------------------------------------------------------------------

  test "search filters supervisors by email or name", %{conn: conn} do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")

    %{user: alice} =
      register("user", %{email: "alice-#{unique()}@example.com", name: "Alice Alpha"})

    %{user: bob} = register("user", %{email: "bob-#{unique()}@example.com", name: "Bob Beta"})

    {:ok, _} = Accounts.add_service_supervisor(service.id, alice.id)
    {:ok, _} = Accounts.add_service_supervisor(service.id, bob.id)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, members_url(service))

    assert has_element?(view, "#remove-#{alice.id}[data-confirm]")
    assert has_element?(view, "#remove-#{bob.id}[data-confirm]")

    view |> element("#search-form") |> render_change(%{"q" => "Alice"})

    assert has_element?(view, "#remove-#{alice.id}")
    refute has_element?(view, "#remove-#{bob.id}")

    view |> element("#search-form") |> render_change(%{"q" => "zzz-nope-#{unique()}"})
    assert has_element?(view, "#service-members-empty")
  end

  test "sorting toggles direction and reorders supervisors", %{conn: conn} do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")
    %{user: u_a} = register("user", %{email: "aaa-#{unique()}@example.com", name: "Alpha"})
    %{user: u_z} = register("user", %{email: "zzz-#{unique()}@example.com", name: "Zeta"})

    {:ok, s_a} = Accounts.add_service_supervisor(service.id, u_a.id)
    {:ok, s_z} = Accounts.add_service_supervisor(service.id, u_z.id)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, members_url(service))

    # Default sort is :email :asc
    html = render(view)
    assert row_order(html, [s_a.id, s_z.id]) == [s_a.id, s_z.id]

    # Clicking Member header toggles to :desc
    html = view |> element("th button[phx-value-field='email']") |> render_click()
    assert html =~ "▼"
    assert row_order(html, [s_a.id, s_z.id]) == [s_z.id, s_a.id]
  end

  defp row_order(html, expected_ids) do
    Regex.scan(~r/<tr[^>]+id="service-member-([^"]+)"/, html)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.filter(&(&1 in expected_ids))
  end

  # --------------------------------------------------------------------------
  # Pagination
  # --------------------------------------------------------------------------

  test "paginates supervisors in DB with 30 per page", %{conn: conn} do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")

    supervisors =
      for i <- 1..31 do
        pad = i |> Integer.to_string() |> String.pad_leading(3, "0")

        user =
          %User{}
          |> Ecto.Changeset.change(%{
            email: "sup-#{pad}-#{unique()}@example.com",
            name: "Supervisor #{pad}",
            password_hash: "not-a-real-hash",
            global_role: "user"
          })
          |> Repo.insert!()

        {:ok, ss} = Accounts.add_service_supervisor(service.id, user.id)
        %{user: user, supervisor: ss}
      end

    first = hd(supervisors)
    last = List.last(supervisors)

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, members_url(service))

    assert has_element?(view, "#service-members-pagination")
    assert has_element?(view, "#service-members-pagination-range", "1–30 de 31")
    assert has_element?(view, "#service-member-#{first.supervisor.id}")
    refute has_element?(view, "#service-member-#{last.supervisor.id}")

    view |> element("#service-members-pagination-page-2") |> render_click()

    assert has_element?(view, "#service-members-pagination-range", "31–31 de 31")
    assert has_element?(view, "#service-member-#{last.supervisor.id}")
    refute has_element?(view, "#service-member-#{first.supervisor.id}")
  end

  # --------------------------------------------------------------------------
  # Add & Remove with audit + PubSub revocation
  # --------------------------------------------------------------------------

  test "adds supervisor via modal search form, audits, and excludes existing supervisors", %{
    conn: conn
  } do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")
    %{user: existing} = register("user", %{email: "match-existing-#{unique()}@example.com"})
    %{user: candidate} = register("user", %{email: "match-candidate-#{unique()}@example.com"})

    {:ok, _} = Accounts.add_service_supervisor(service.id, existing.id)

    Phoenix.PubSub.subscribe(Tokengate.PubSub, Accounts.supervised_services_topic(candidate.id))

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, members_url(service))

    view |> element("#new-member-btn") |> render_click()
    assert has_element?(view, "#add-service-member-modal")
    assert has_element?(view, "#add-service-member-form[phx-change='search_users']")

    # Search matches candidate but excludes already-assigned existing supervisor
    view
    |> element("#add-service-member-form")
    |> render_change(%{"search" => %{"query" => "match-"}})

    assert has_element?(view, "#add-user-#{candidate.id}")
    refute has_element?(view, "#add-user-#{existing.id}")

    view |> element("#add-user-#{candidate.id}") |> render_click()

    refute has_element?(view, "#add-service-member-modal")
    assert has_element?(view, "#remove-#{candidate.id}")
    assert Accounts.supervises_service?(candidate.id, service.id)

    assert_receive {:supervisor_added, service_id}
    assert service_id == service.id

    assert [audit] =
             Tokengate.Auditing.list_audit_logs(%{
               action: "service_supervisor.add",
               entity_id: service.id
             })

    assert audit.changes["user_id"] == candidate.id
  end

  test "removes supervisor, audits, and immediately revokes open SupervisedServicesLive via PubSub",
       %{conn: conn} do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")
    %{user: supervisor, password: sup_password} = register("user")

    {:ok, _} = Accounts.add_service_supervisor(service.id, supervisor.id)

    # Open SupervisedServicesLive as the supervisor
    sup_conn = build_conn() |> login(supervisor, sup_password)
    {:ok, sup_view, sup_html} = live(sup_conn, ~p"/services/supervised")
    assert sup_html =~ service.name

    # Remove supervisor from ServiceMembersLive
    admin_conn = login(conn, admin, password)
    {:ok, admin_view, _html} = live(admin_conn, members_url(service))

    admin_view |> element("#remove-#{supervisor.id}") |> render_click()

    refute has_element?(admin_view, "#remove-#{supervisor.id}")
    refute Accounts.supervises_service?(supervisor.id, service.id)

    assert [audit] =
             Tokengate.Auditing.list_audit_logs(%{
               action: "service_supervisor.remove",
               entity_id: service.id
             })

    assert audit.changes["user_id"] == supervisor.id

    # The supervisor's open view receives {:supervisor_removed, service_id} and redirects to /dashboard
    assert_redirect(sup_view, "/dashboard")
  end

  test "malformed user ids never crash add_member or remove_member", %{conn: conn} do
    service = service_fixture()
    %{user: admin, password: password} = register("admin")

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, members_url(service))

    assert render_hook(view, "add_member", %{"user-id" => "not-a-uuid"}) =~ "No se pudo agregar"
    assert render_hook(view, "remove_member", %{"user-id" => "not-a-uuid"}) =~ "No se pudo"
    assert has_element?(view, "#new-member-btn")
  end
end
