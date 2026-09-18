defmodule Tokengate.Repo.Migrations.Notifications do
  use Ecto.Migration

  @moduledoc """
  Notificaciones a Telegram: ajustes del bot, chats vinculados y el registro de
  envíos.

    * `notification_settings` — fila singleton (id = 1), patrón `global_settings`:
      token del bot (cifrado), lista de eventos habilitados y horas de silencio.
    * `telegram_links` — qué `chat_id` pertenece a qué usuario. Sólo un admin
      vinculado puede disparar comandos entrantes (Fase 2).
    * `notifications` — el log de cada evento emitido y su estado de entrega.
      Es la fuente de la vista de "Envíos" y da idempotencia/reintentos.
  """

  def change do
    create table(:notification_settings, primary_key: false) do
      add :id, :integer, primary_key: true, default: 1
      add :bot_token, :binary
      add :bot_username, :string
      add :enabled_events, :map, default: %{}, null: false
      add :quiet_hours_from, :string
      add :quiet_hours_to, :string

      timestamps(type: :utc_datetime)
    end

    execute(
      "INSERT INTO notification_settings (id, enabled_events, inserted_at, updated_at) VALUES (1, '{}', NOW(), NOW())",
      "DELETE FROM notification_settings WHERE id = 1"
    )

    create table(:telegram_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, autogenerate: true
      add :chat_id, :string, null: false
      # "chat" (privado), "group" o "channel". Sólo informativo para la UI:
      # Telegram enruta por `chat_id`; un canal con topics usa además `thread_id`.
      add :kind, :string, null: false, default: "chat"
      # `message_thread_id` del topic cuando el destino es un foro. nil = el
      # mensaje va al hilo general del chat/canal.
      add :thread_id, :string
      add :telegram_username, :string
      add :label, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:telegram_links, [:chat_id, :thread_id])

    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true, autogenerate: true
      add :event, :string, null: false
      add :severity, :string, null: false, default: "info"
      add :entity_type, :string
      add :entity_id, :string
      add :target_label, :string
      add :payload, :map, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :telegram_message_id, :string
      add :error, :string
      add :sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:inserted_at])
    create index(:notifications, [:event])
    create index(:notifications, [:status])
  end
end
