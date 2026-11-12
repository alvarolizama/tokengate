defmodule Tokengate.Repo.Migrations.CreateNotificationDeliveries do
  use Ecto.Migration

  # Progreso de entrega POR DESTINO (auditoría Alto 4). Antes el worker
  # marcaba la notificación `sent` con el primer `{:ok, _}` y terminaba: los
  # demás chats quedaban sin mensaje y, en un reintento, se reenviaba a TODOS
  # (incluido el que ya había recibido). Con una fila por (notificación,
  # link) el reintento sabe exactamente qué falta.
  #
  # `link_id` es la identidad del destino: un `telegram_links` ya es único por
  # (chat_id, thread_id), así que link_id evita el problema de los NULLs
  # distintos en un índice único sobre thread_id nullable.
  def change do
    create table(:notification_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true, autogenerate: true

      add :notification_id, references(:notifications, type: :binary_id, on_delete: :delete_all),
        null: false

      add :link_id, references(:telegram_links, type: :binary_id, on_delete: :delete_all),
        null: false

      add :chat_id, :string, null: false
      add :thread_id, :string
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :telegram_message_id, :string
      add :error, :string
      add :sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # La clave natural: una fila de progreso por notificación y destino. Sirve
    # también la lectura "qué falta" por notificación (prefijo del índice).
    create unique_index(:notification_deliveries, [:notification_id, :link_id])
  end
end
