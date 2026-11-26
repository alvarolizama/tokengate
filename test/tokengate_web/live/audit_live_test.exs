defmodule TokengateWeb.AuditLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Tokengate.{Accounts, Auditing}

  defp register(role) do
    u = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "audit-live-#{u}@example.com",
        name: "User #{u}",
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

  test "admin sees recorded audit entries", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, log} =
      Auditing.log(admin, "model.create", "model", "m-1", %{"name" => "gpt-x"}, %{
        ip: "10.0.0.1"
      })

    conn = login(conn, admin, password)

    {:ok, view, html} = live(conn, ~p"/operations/audit")

    # Default UI language is English: the msgid is rendered as-is.
    assert html =~ "Audit"
    assert html =~ "Who did what, to what, and when"
    refute html =~ "Auditoría"
    assert html =~ "model.create"
    assert html =~ admin.email

    # The .table contract: tbody carries the id and each row keeps its dom id.
    assert has_element?(view, "tbody#audit-rows")
    assert has_element?(view, "tr#audit-#{log.id}")

    # And the Spanish catalog still renders the same screen in Spanish.
    {:ok, _admin} = Accounts.update_user_locale(admin, "es")
    {:ok, _view_es, html_es} = live(recycle(conn), ~p"/operations/audit")

    assert html_es =~ "Auditoría"
    assert html_es =~ "Quién hizo qué"
    refute html_es =~ "Who did what"
  end

  test "filtering by action narrows the table", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, _} = Auditing.log(admin, "model.create", "model", "m-1", %{}, %{})
    {:ok, _} = Auditing.log(admin, "topup.create", "topup", "t-1", %{}, %{})

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/audit")

    view
    |> form("#audit-filters", %{"f" => %{"action" => "topup.create"}})
    |> render_change()

    assert has_element?(view, "#audit-rows", "topup.create")
    refute has_element?(view, "#audit-rows", "model.create")

    # No match → the .table empty-state slot renders instead of a colspan row.
    view
    |> form("#audit-filters", %{"f" => %{"action" => "does.not.exist"}})
    |> render_change()

    assert has_element?(view, "#audit-rows-empty", "No events for the selected filters.")
    refute has_element?(view, "#audit-rows")
  end

  test "non-admin is redirected to the dashboard", %{conn: conn} do
    %{user: user, password: password} = register("user")
    conn = login(conn, user, password)

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/operations/audit")
  end

  test "CSV export returns an attachment", %{conn: conn} do
    %{user: admin, password: password} = register("admin")
    {:ok, _} = Auditing.log(admin, "model.create", "model", "m-1", %{}, %{})

    conn =
      conn
      |> login(admin, password)
      |> get("/operations/audit/export?action=model.create")

    assert response(conn, 200) =~ "model.create"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
  end

  test "non-numeric go_to_page does not crash and date filters respect user timezone", %{
    conn: conn
  } do
    %{user: admin, password: password} = register("admin")
    {:ok, admin} = Accounts.update_user_timezone(admin, "Europe/Madrid")

    # 2026-11-24 23:30 UTC == 2026-11-25 00:30 CET (Europe/Madrid).
    {:ok, late_log} =
      %Tokengate.Auditing.AuditLog{}
      |> Tokengate.Auditing.AuditLog.changeset(%{
        user_id: admin.id,
        actor_email: admin.email,
        actor_role: admin.global_role,
        action: "model.create",
        entity_type: "model",
        entity_id: "m-tz",
        inserted_at: ~U[2026-11-24 23:30:00Z]
      })
      |> Tokengate.Repo.insert()

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/audit")

    # Invalid page param must be ignored safely.
    render_click(view, "go_to_page", %{"page" => "not-a-number"})
    assert has_element?(view, "tr#audit-#{late_log.id}")

    # Filtering for 2026-11-25 in Europe/Madrid matches 2026-11-24 23:30 UTC.
    view
    |> form("#audit-filters", %{"f" => %{"from" => "2026-11-25", "to" => "2026-11-25"}})
    |> render_change()

    assert has_element?(view, "tr#audit-#{late_log.id}")
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.export_query =~ "from=2026-11-25"
    assert assigns.export_query =~ "to=2026-11-25"
    assert has_element?(view, "#audit-filters input[name='f[ip]'][phx-debounce='300']")
    assert has_element?(view, "#audit-filters input[name='f[action]'][phx-debounce='300']")
    assert has_element?(view, "#audit-filters input[name='f[target_label]'][phx-debounce='300']")
  end

  test "quick search, target_label filter, date presets and detail modal work", %{conn: conn} do
    %{user: admin, password: password} = register("admin")

    {:ok, log} =
      Auditing.log(
        admin,
        "provider.update",
        "provider",
        "p-1",
        %{"name" => "OpenRouter"},
        %{target_label: "OpenRouter", ip: "198.51.100.9"}
      )

    conn = login(conn, admin, password)
    {:ok, view, _html} = live(conn, ~p"/operations/audit")

    # Quick search matches across target_label / action / IP
    view |> element("#search-form") |> render_change(%{"q" => "OpenRouter"})
    assert has_element?(view, "tr#audit-#{log.id}")

    view |> element("#search-form") |> render_change(%{"q" => "no-such-match"})
    refute has_element?(view, "tr#audit-#{log.id}")

    # Clear filters resets search + form
    view |> element("#audit-clear") |> render_click()
    assert has_element?(view, "tr#audit-#{log.id}")

    # Detail modal opens with formatted JSON changes
    view |> element("#audit-detail-#{log.id}") |> render_click()
    assert has_element?(view, "#audit-detail-modal")
    assert has_element?(view, "#audit-detail-changes", "OpenRouter")

    view |> element("#audit-detail-modal .btn-circle") |> render_click()
    refute has_element?(view, "#audit-detail-modal")

    # Date preset populates from/to
    view |> element("#audit-preset-today") |> render_click()
    assert has_element?(view, "tr#audit-#{log.id}")
  end
end
