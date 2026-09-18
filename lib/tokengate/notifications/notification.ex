defmodule Tokengate.Notifications.Notification do
  @moduledoc """
  One emitted notification and the state of its delivery.

  El registro es la **fuente de idempotencia y de reintentos**: se inserta en
  `pending` en el momento de `emit/2` y `TelegramWorker` lo pasa a `sent` o
  `failed`. La vista de Operaciones lee de aquí.

  Contiene **sólo ids, nombres, prefijos y montos** — nunca el valor de una API
  key, una credencial ni un token: Telegram es un tercero y el cuerpo del
  mensaje se trata como semi-público.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending sent failed)
  # Sólo información; el detalle vive en `Tokengate.Notifications.Events`.
  @severities ~w(critical warning info security)

  schema "notifications" do
    field :event, :string
    field :severity, :string, default: "info"
    field :entity_type, :string
    field :entity_id, :string
    field :target_label, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :telegram_message_id, :string
    field :error, :string
    field :sent_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(event severity entity_type entity_id target_label payload
    status attempts telegram_message_id error sent_at)a
  @required ~w(event severity)a

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Statuses a notification can be in."
  def statuses, do: @statuses

  @doc "Severities a notification can carry."
  def severities, do: @severities
end
