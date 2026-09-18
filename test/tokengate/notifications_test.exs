defmodule Tokengate.NotificationsTest do
  use Tokengate.DataCase, async: false
  use Oban.Testing, repo: Tokengate.Repo

  alias Tokengate.Notifications
  alias Tokengate.Notifications.Notification
  alias Tokengate.Notifications.TelegramWorker

  setup do
    Notifications.clear_throttle()
    # A clean settings row between tests (the singleton is seeded by migration).
    Notifications.update_settings(%{"enabled_events" => %{}, "bot_username" => nil})
    :ok
  end

  describe "emit/2" do
    test "persists a pending notification and enqueues the delivery job" do
      assert :ok =
               Notifications.emit(:credential_disabled, %{
                 entity_type: "credential",
                 entity_id: "cred-1",
                 target_label: "OpenRouter #1",
                 reason: "auth_error_402"
               })

      assert [%Notification{} = n] = Notifications.list_notifications()
      assert n.event == "credential_disabled"
      assert n.severity == "critical"
      assert n.status == "pending"

      assert_enqueued(worker: TelegramWorker, args: %{"notification_id" => n.id})
    end

    test "throttles repeats of the same event+entity within the cooldown" do
      attrs = %{entity_type: "credential", entity_id: "cred-x"}

      assert :ok = Notifications.emit(:credential_disabled, attrs)
      assert :ok = Notifications.emit(:credential_disabled, attrs)

      assert Notifications.count_notifications() == 1
    end

    test "does not emit a disabled event" do
      # user_created is OFF by default and, with an empty enabled map, stays off.
      assert :ok = Notifications.emit(:user_created, %{entity_id: "u1"})
      assert Notifications.count_notifications() == 0
    end

    test "ignores unknown events" do
      assert :ok = Notifications.emit(:not_a_real_event, %{})
      assert Notifications.count_notifications() == 0
    end

    test "quiet hours block non-critical events but let critical through" do
      {:ok, _} =
        Notifications.update_settings(%{
          "quiet_hours_from" => "00:00",
          "quiet_hours_to" => "23:59"
        })

      assert :ok = Notifications.emit(:topup_changed, %{entity_id: "t1"})
      assert :ok = Notifications.emit(:credential_disabled, %{entity_id: "c1"})

      events = Enum.map(Notifications.list_notifications(), & &1.event)
      assert events == ["credential_disabled"]
    end
  end

  describe "from_audit/4" do
    test "maps an audited action to its catalog event" do
      assert :ok =
               Notifications.from_audit("topup.create", "topup", "top-1", %{"label" => "Bonus"})

      assert [%Notification{event: "topup_changed", entity_type: "topup"}] =
               Notifications.list_notifications()
    end

    test "does nothing for actions that do not notify" do
      assert :ok = Notifications.from_audit("provider.update", "provider", "p1", %{})
      assert Notifications.count_notifications() == 0
    end
  end

  describe "links" do
    test "creates a channel link with a topic id" do
      assert {:ok, link} =
               Notifications.create_link(%{
                 "chat_id" => "-1001234567890",
                 "kind" => "channel",
                 "thread_id" => "42",
                 "label" => "Ops channel"
               })

      assert link.thread_id == "42"
      assert [target] = Notifications.linked_targets()
      assert target.chat_id == "-1001234567890"
    end

    test "normalizes a blank topic id to nil" do
      assert {:ok, link} = Notifications.create_link(%{"chat_id" => "1", "thread_id" => "  "})
      assert link.thread_id == nil
    end

    test "rejects an unknown kind" do
      assert {:error, changeset} =
               Notifications.create_link(%{"chat_id" => "1", "kind" => "wat"})

      assert "is invalid" in errors_on(changeset).kind
    end

    test "deletes a link" do
      {:ok, link} = Notifications.create_link(%{"chat_id" => "1"})
      assert :ok = Notifications.delete_link(link.id)
      assert Notifications.list_links() == []
    end
  end

  describe "settings" do
    test "stores the bot token encrypted (never in clear)" do
      {:ok, settings} = Notifications.put_token("123456:ABC-DEF")

      refute settings.bot_token == "123456:ABC-DEF"

      assert {:ok, "123456:ABC-DEF"} =
               Tokengate.Notifications.SecretBox.decrypt(settings.bot_token)
    end

    test "enabled_events overrides the catalog default" do
      # user_created is OFF by default; enabling it explicitly turns it on.
      {:ok, _} = Notifications.update_settings(%{"enabled_events" => %{"user_created" => true}})
      assert Notifications.enabled?(:user_created)
    end
  end
end
