defmodule Tokengate.Notifications.Delivery do
  @moduledoc """
  Progreso de entrega de UNA notificación a UN chat vinculado.

  `TelegramWorker` escribe una fila por (notificación, link) antes de hablar
  con Telegram y la actualiza con el desenlace:

    * `"pending"` — todavía no entregada, o el último intento falló de forma
      **transitoria** (transporte / 5xx). Un reintento de Oban sólo vuelve a
      enviar las `pending`.
    * `"sent"` — entregada; guarda el `message_id` de Telegram. Nunca se
      reenvía.
    * `"failed"` — rechazo terminal del destino (4xx / `ok:false`: chat
      borrado, bot expulsado). Reintentar no cambia el resultado.

  Sin esta tabla, `Notification` sólo tenía un estado global: con el primer
  `{:ok, _}` se marcaba `sent` y los chats restantes quedaban sin mensaje
  (auditoría Alto 4).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending sent failed)

  schema "notification_deliveries" do
    field :chat_id, :string
    field :thread_id, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :telegram_message_id, :string
    field :error, :string
    field :sent_at, :utc_datetime

    belongs_to :notification, Tokengate.Notifications.Notification
    belongs_to :link, Tokengate.Notifications.Link

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(notification_id link_id chat_id thread_id status attempts
    telegram_message_id error sent_at)a
  @required ~w(notification_id link_id chat_id)a

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:notification_id, :link_id])
  end

  @doc "Statuses a delivery row can be in."
  def statuses, do: @statuses
end
