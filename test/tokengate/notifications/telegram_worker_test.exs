defmodule Tokengate.Notifications.TelegramWorkerTest do
  @moduledoc """
  Integration tests for `TelegramWorker` against a live Bandit server standing in
  for the Telegram Bot API: delivery to every linked target, `message_thread_id`
  for a channel topic, retry semantics (200 → :ok, 400 → discard, 500 → error)
  and the no-targets case.
  """

  use Tokengate.DataCase, async: false

  alias Tokengate.Notifications
  alias Tokengate.Notifications.Delivery
  alias Tokengate.Notifications.Notification
  alias Tokengate.Notifications.TelegramWorker

  @port 41335

  defmodule TestPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:captured, %{path: conn.request_path, body: decoded}})
      end

      chat = to_string(decoded["chat_id"] || "")
      fail_chats = :persistent_term.get({__MODULE__, :fail_chats}, true)

      cond do
        # Fallo por DESTINO, independiente del path: permite un envío con un
        # chat sano y otro que falla. `fail_chats` se apaga para simular que el
        # destino se recuperó en el reintento.
        fail_chats and String.starts_with?(chat, "flaky") ->
          json(conn, 500, %{"ok" => false, "description" => "flaky chat"})

        String.starts_with?(chat, "bad") ->
          json(conn, 400, %{"ok" => false, "description" => "chat not found"})

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
    :persistent_term.put({TestPlug, :fail_chats}, true)

    start_supervised!({Bandit, plug: TestPlug, scheme: :http, ip: :loopback, port: @port})
    Notifications.clear_throttle()

    on_exit(fn ->
      Application.put_env(:tokengate, :telegram_bot_token, original_token)
      Application.put_env(:tokengate, :telegram_api_base, original_base)
      :persistent_term.erase({TestPlug, :fail_chats})
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

  # Auditoría Alto 4: antes, con el primer `{:ok, _}` la notificación se
  # marcaba `sent` y los envíos restantes se descartaban de la vista. Un
  # reintento además reenviaba a TODOS.
  describe "progreso por destino (Alto 4)" do
    test "una entrega OK no oculta el fallo transitorio de otro chat" do
      {:ok, _} = Notifications.create_link(%{"chat_id" => "555"})
      {:ok, _} = Notifications.create_link(%{"chat_id" => "flaky-chat"})

      n = notification_fixture()

      # El chat "flaky-chat" devuelve 500 → transitorio → reintento de Oban.
      assert {:error, reason} = TelegramWorker.perform(job(n))
      assert reason =~ "flaky-chat"

      # Los dos envíos del primer intento (uno OK, uno fallido) ya están en el
      # buzón: se drenan para que el `refute_receive` del reintento mida sólo
      # lo que se manda DESPUÉS.
      assert_receive {:captured, %{body: %{"chat_id" => "555"}}}
      assert_receive {:captured, %{body: %{"chat_id" => "flaky-chat"}}}

      notification = Tokengate.Repo.get!(Notification, n.id)
      assert notification.status == "pending"

      deliveries = Enum.sort_by(Repo.all(Delivery), & &1.chat_id)

      assert [%{chat_id: "555", status: "sent"}, %{chat_id: "flaky-chat", status: "pending"}] =
               deliveries

      # El reintento sólo manda lo pendiente: el chat 555 ya recibió.
      :persistent_term.put({TestPlug, :fail_chats}, false)

      assert :ok = TelegramWorker.perform(job(n))

      assert_receive {:captured, %{body: %{"chat_id" => "flaky-chat"}}}
      # exactly one send on the retry — the already-delivered chat is skipped
      refute_receive {:captured, _}, 200

      deliveries = Enum.sort_by(Repo.all(Delivery), & &1.chat_id)
      assert Enum.all?(deliveries, &(&1.status == "sent"))
      assert Tokengate.Repo.get!(Notification, n.id).status == "sent"
    end

    test "un rechazo terminal no frena a los demás chats ni se reintenta" do
      {:ok, _} = Notifications.create_link(%{"chat_id" => "555"})
      {:ok, _} = Notifications.create_link(%{"chat_id" => "bad-chat"})

      n = notification_fixture()

      # "bad-chat" devuelve 400 (terminal) sin tocar al chat sano.
      assert :ok = TelegramWorker.perform(job(n))

      assert_receive {:captured, %{body: %{"chat_id" => "555"}}}

      notification = Tokengate.Repo.get!(Notification, n.id)
      assert notification.status == "sent"
      assert notification.error =~ "bad-chat"

      statuses = Repo.all(Delivery) |> Map.new(&{&1.chat_id, &1.status})
      assert statuses == %{"555" => "sent", "bad-chat" => "failed"}
    end

    test "el progreso sobrevive al reintento: no se reenvía lo ya entregado" do
      {:ok, _} = Notifications.create_link(%{"chat_id" => "555"})
      n = notification_fixture()

      assert :ok = TelegramWorker.perform(job(n))
      assert_receive {:captured, %{body: %{"chat_id" => "555"}}}

      # Segundo attempt del mismo job (p. ej. rescate de Lifeline).
      assert :ok = TelegramWorker.perform(job(n))
      refute_receive {:captured, _}, 200
      assert [%{status: "sent", attempts: 1}] = Repo.all(Delivery)
    end

    test "un reenvío manual reintenta el chat rechazado (status pending + error nil)" do
      # Base limpio: el caso "400 terminal" de más arriba apunta a /bad y este
      # test necesita que el destino ya funcione.
      Application.put_env(:tokengate, :telegram_api_base, "http://localhost:#{@port}")
      :persistent_term.put({TestPlug, :fail_chats}, false)

      {:ok, _} = Notifications.create_link(%{"chat_id" => "bad-chat"})
      n = notification_fixture()

      assert {:discard, _} = TelegramWorker.perform(job(n))
      assert [%{status: "failed"}] = Repo.all(Delivery)

      # Lo que hace la vista de Operaciones al pulsar "reenviar" (sobre la fila
      # fresca: `change/2` ignora un valor igual al del struct).
      Repo.get!(Notification, n.id)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:status, "pending")
      |> Ecto.Changeset.force_change(:error, nil)
      |> Repo.update!()

      # El admin arregló el destino: el link ahora apunta a un chat válido.
      Repo.update_all(Tokengate.Notifications.Link, set: [chat_id: "555"])

      assert :ok = TelegramWorker.perform(job(n))
      assert_receive {:captured, %{body: %{"chat_id" => "555"}}}
      assert [%{status: "sent"}] = Repo.all(Delivery)
    end
  end
end
