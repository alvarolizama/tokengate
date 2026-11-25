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
    # Settings are a global singleton cached in ETS/Agent, so a token stored by
    # one test would leak into the next (the DB sandbox rolls back, the cache
    # does not).
    Notifications.update_settings(%{"enabled_events" => %{}, "bot_username" => nil})
    Notifications.clear_token()
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

    # Both streamed tables start empty and render their .table empty-state
    # (the id is derived from the tbody id: "#links-empty", "#notifications-empty").
    assert has_element?(view, "#links-empty", "No linked chats yet.")
    assert has_element?(view, "#notifications-empty", "No notifications emitted yet.")
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

  test "submitting an empty token keeps the stored one (F9/P9)", %{conn: conn} do
    {:ok, _settings} = Notifications.put_token("123456:STORED-TOKEN")

    {:ok, view, _html} = live(admin_conn(conn), ~p"/operations/notifications")

    assert has_element?(view, "#notifications-bot-card", "Stored token set")

    # The input is never prefilled, so an empty submit must be a no-op — it
    # used to clear the stored token.
    view
    |> form("#notifications-token-form", %{"token" => %{"bot_token" => "   "}})
    |> render_submit()

    settings = Notifications.get_settings()
    refute is_nil(settings.bot_token)

    assert {:ok, "123456:STORED-TOKEN"} =
             Tokengate.Notifications.SecretBox.decrypt(settings.bot_token)

    # The badge still says the stored token is there.
    assert has_element?(view, "#notifications-bot-card", "Stored token set")

    # Clearing has its own explicit button and still works.
    view |> element("#clear-token-btn") |> render_click()

    assert is_nil(Notifications.get_settings().bot_token)
    refute has_element?(view, "#clear-token-btn")
  end

  test "malformed or missing ids in resend and remove_link do not crash", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), ~p"/operations/notifications")

    render_click(view, "resend", %{"id" => "not-a-uuid"})
    assert has_element?(view, "#flash-error")

    render_click(view, "resend", %{"id" => Ecto.UUID.generate()})
    assert has_element?(view, "#flash-error")

    render_click(view, "remove_link", %{"id" => "not-a-uuid"})
    assert has_element?(view, "#flash-error")
  end
end
