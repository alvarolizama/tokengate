defmodule TokengateWeb.NotificationsLiveTest do
  use TokengateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tokengate.Accounts
  alias Tokengate.Notifications

  defp unique, do: System.unique_integer([:positive])

  defp register(role) do
    u = unique()

    {:ok, user} =
      Accounts.register_user(%{
        email: "notif-#{u}@example.com",
        name: "Notif #{u}",
        password: "password-secret-#{u}1",
        global_role: role
      })

    %{user: user, password: "password-secret-#{u}1"}
  end

  defp login(conn, %{user: user, password: password}) do
    conn |> post(~p"/login", %{email: user.email, password: password}) |> recycle()
  end

  defp admin_conn(conn), do: login(conn, register("admin"))

  setup do
    Notifications.clear_throttle()
    :ok
  end

  test "admin sees the notifications section with all cards", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/operations/notifications")

    assert has_element?(view, "#notifications-bot-card")
    assert has_element?(view, "#notifications-events-card")
    assert has_element?(view, "#notifications-quiet-card")
    assert has_element?(view, "#notifications-links-card")
    assert has_element?(view, "#notifications-log-card")
    assert has_element?(view, "#link-form")
  end

  test "non-admins are redirected away", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             live(login(conn, register("user")), ~p"/operations/notifications")
  end

  test "toggling an event persists it", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/operations/notifications")

    # user_created is OFF by default.
    assert has_element?(view, "#toggle-event-user_created", "Off")

    view |> element("#toggle-event-user_created") |> render_click()

    assert has_element?(view, "#toggle-event-user_created", "On")
    assert Notifications.enabled?(:user_created)
  end

  test "linking a chat with a topic id shows it in the table", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/operations/notifications")

    view
    |> form("#link-form", %{
      "link" => %{
        "chat_id" => "-100777",
        "kind" => "channel",
        "thread_id" => "15",
        "label" => "Ops"
      }
    })
    |> render_submit()

    assert has_element?(view, "#links", "-100777")
    assert has_element?(view, "#links", "15")

    assert [link] = Notifications.list_links()
    assert link.thread_id == "15"
  end
end
