defmodule Tokengate.Notifications.TelegramWorkerTest do
  @moduledoc """
  Integration tests for `TelegramWorker` against a live Bandit server standing in
  for the Telegram Bot API: delivery to every linked target, `message_thread_id`
  for a channel topic, retry semantics (200 → :ok, 400 → discard, 500 → error)
  and the no-targets case.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Notifications
  alias Tokengate.Notifications.Notification
  alias Tokengate.Notifications.TelegramWorker

  @port 41335

  defmodule TestPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:captured, %{path: conn.request_path, body: Jason.decode!(body)}})
      end

      cond do
        "bad" in conn.path_info ->
          json(conn, 400, %{"ok" => false, "description" => "chat not found"})

        "broken" in conn.path_info ->
          json(conn, 500, %{"ok" => false})

        true ->
          json(conn, 200, %{"ok" => true, "result" => %{"message_id" => 99}})
      end
    end

    defp json(conn, status, map) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(map))
    end
  end

  setup do
    original_token = Application.get_env(:tokengate, :telegram_bot_token)
    original_base = Application.get_env(:tokengate, :telegram_api_base)

    Application.put_env(:tokengate, :telegram_bot_token, "test-token")
    Application.put_env(:tokengate, :telegram_api_base, "http://localhost:#{@port}")
    :persistent_term.put({TestPlug, :test_pid}, self())

    start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: :loopback, port: @port})
    Notifications.clear_throttle()

    on_exit(fn ->
      Application.put_env(:tokengate, :telegram_bot_token, original_token)
      Application.put_env(:tokengate, :telegram_api_base, original_base)
    end)

    :ok
  end

  defp notification_fixture(attrs \\ %{}) do
    {:ok, n} =
      %Notification{}
      |> Notification.changeset(
        Map.merge(
          %{event: "credential_disabled", severity: "critical", status: "pending"},
          attrs
        )
      )
      |> Tokengate.Repo.insert()

    n
  end

  defp job(notification), do: %Oban.Job{args: %{"notification_id" => notification.id}}

  test "delivers to a linked chat and marks it sent" do
    {:ok, _} = Notifications.create_link(%{"chat_id" => "555"})
    n = notification_fixture()

    assert :ok = TelegramWorker.perform(job(n))
    assert_receive {:captured, %{path: path, body: body}}
    assert path =~ "/sendMessage"
    assert body["chat_id"] == "555"
    refute Map.has_key?(body, "message_thread_id")

    assert Tokengate.Repo.get!(Notification, n.id).status == "sent"
  end

  test "publishes into a channel topic with message_thread_id" do
    {:ok, _} =
      Notifications.create_link(%{
        "chat_id" => "-100123",
        "kind" => "channel",
        "thread_id" => "77"
      })

    n = notification_fixture()

    assert :ok = TelegramWorker.perform(job(n))
    assert_receive {:captured, %{body: body}}
    assert body["chat_id"] == "-100123"
    assert body["message_thread_id"] == 77
  end

  test "discards when Telegram rejects the message (4xx / ok:false)" do
    Application.put_env(:tokengate, :telegram_api_base, "http://localhost:#{@port}/bad")
    {:ok, _} = Notifications.create_link(%{"chat_id" => "555"})
    n = notification_fixture()

    assert {:discard, _} = TelegramWorker.perform(job(n))
    assert Tokengate.Repo.get!(Notification, n.id).status == "failed"
  end

  test "retries on a 5xx" do
    Application.put_env(:tokengate, :telegram_api_base, "http://localhost:#{@port}/broken")
    {:ok, _} = Notifications.create_link(%{"chat_id" => "555"})
    n = notification_fixture()

    assert {:error, _} = TelegramWorker.perform(job(n))
  end

  test "discards and marks failed when there are no linked chats" do
    n = notification_fixture()

    assert {:discard, "no linked chats"} = TelegramWorker.perform(job(n))
    failed = Tokengate.Repo.get!(Notification, n.id)
    assert failed.status == "failed"
    assert failed.error == "no linked chats"
  end
end
