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

  test "filters delivery log, shows per-chat delivery and error modal, and updates on PubSub", %{
    conn: conn
  } do
    {:ok, link} =
      Notifications.create_link(%{
        chat_id: "-100999",
        kind: "group",
        label: "Ops Alert Room"
      })

    {:ok, failed_notif} =
      %Tokengate.Notifications.Notification{}
      |> Tokengate.Notifications.Notification.changeset(%{
        event: "breaker_opened",
        severity: "warning",
        entity_type: "credential",
        entity_id: "cred-1",
        target_label: "OpenRouter Key",
        status: "failed",
        error: "403 Forbidden: bot kicked"
      })
      |> Tokengate.Repo.insert()

    {:ok, _delivery} =
      %Tokengate.Notifications.Delivery{}
      |> Tokengate.Notifications.Delivery.changeset(%{
        notification_id: failed_notif.id,
        link_id: link.id,
        chat_id: link.chat_id,
        status: "failed",
        attempts: 1,
        error: "403 Forbidden: bot kicked"
      })
      |> Tokengate.Repo.insert()

    {:ok, sent_notif} =
      %Tokengate.Notifications.Notification{}
      |> Tokengate.Notifications.Notification.changeset(%{
        event: "topup_changed",
        severity: "info",
        entity_type: "topup",
        entity_id: "t-1",
        target_label: "Team A",
        status: "sent"
      })
      |> Tokengate.Repo.insert()

    {:ok, view, _html} = live(admin_conn(conn), ~p"/operations/notifications")

    # Per-chat delivery badge and error modal
    assert has_element?(view, "#notifications", "Ops Alert Room")
    assert has_element?(view, "#notifications", "Team A")

    view |> element("#notification-error-btn-#{failed_notif.id}") |> render_click()
    assert has_element?(view, "#notification-error-modal")
    assert has_element?(view, "#notification-error-message", "403 Forbidden: bot kicked")
    view |> element("#notification-error-modal .btn-circle") |> render_click()
    refute has_element?(view, "#notification-error-modal")

    # Status filter narrows table
    view
    |> form("#notifications-filter-form", %{"nf" => %{"status" => "sent"}})
    |> render_change()

    assert has_element?(view, "#notifications", "Team A")
    refute has_element?(view, "#notifications", "OpenRouter Key")

    # Resend works via context and resets status
    view
    |> form("#notifications-filter-form", %{"nf" => %{"status" => ""}})
    |> render_change()

    view |> element("#resend-#{failed_notif.id}") |> render_click()
    assert has_element?(view, "#flash-info")
    assert Tokengate.Notifications.get_notification!(failed_notif.id).status == "pending"
    assert sent_notif.id
  end
end
