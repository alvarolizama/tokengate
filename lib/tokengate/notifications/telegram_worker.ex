defmodule Tokengate.Notifications.TelegramWorker do
  @moduledoc """
  Oban worker que entrega una `Notification` a todos los chats vinculados.

  ## Progreso por destino (auditoría Alto 4)

  Antes el worker enviaba a todos los chats y, con el **primer** `{:ok, _}`,
  marcaba la notificación `sent` y devolvía `:ok`: los chats cuyo envío falló
  quedaban sin mensaje para siempre, y un reintento reenviaba a TODOS
  (duplicando en los que ya habían recibido).

  Ahora el progreso vive en `Tokengate.Notifications.Delivery`, una fila por
  (notificación, link). El reintento de Oban sólo envía las filas `pending`:

    * `sent`   — ya entregada; se omite (nunca se reenvía).
    * `failed` — rechazo terminal del destino (4xx / `ok:false`); se omite.
    * `pending`— pendiente o fallo transitorio; es lo único que se reintenta.

  ## Retry semantics

    * todas entregadas → `:ok` y la notificación pasa a `sent`;
    * queda alguna `pending` (transporte / 5xx) → `{:error, _}` — Oban
      reintenta con backoff y sólo reenvía lo pendiente;
    * ninguna entregada y sin pendientes (todas rechazadas) → `{:discard, _}`
      y la notificación queda `failed`.

  El worker **no** habla con Telegram hasta tener al menos un chat vinculado: sin
  destinos la notificación se descarta y queda `failed` con la razón, para que
  la vista de Operaciones muestre por qué no salió.

  El cuerpo del mensaje lleva **sólo** ids, etiquetas y montos (ver `Events`).
  Nunca el valor de un secreto.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5

  require Logger

  alias Tokengate.Notifications
  alias Tokengate.Notifications.Delivery
  alias Tokengate.Notifications.Events
  alias Tokengate.Notifications.Notification
  alias Tokengate.Notifications.Telegram
  alias Tokengate.Repo

  @impl true
  def perform(%Oban.Job{args: %{"notification_id" => id}}) do
    case Repo.get(Notification, id) do
      nil ->
        {:discard, "notification #{id} not found"}

      notification ->
        deliver(notification)
    end
  end

  defp deliver(notification) do
    case Notifications.linked_targets() do
      [] ->
        mark(notification, %{status: "failed", error: "no linked chats"})
        {:discard, "no linked chats"}

      targets ->
        text = render(notification)
        opts = [retry_terminal: manual_resend?(notification)]
        outcomes = Enum.map(targets, &deliver_to(notification, &1, text, opts))
        finalize(notification, outcomes)
    end
  end

  # Un reintento AUTOMÁTICO de Oban (la notificación ya tiene `error`) respeta
  # los rechazos terminales: reenviarle un 400 al mismo chat sólo repite el
  # error. Un reenvío MANUAL (la vista de Operaciones pone la notificación en
  # `pending` y limpia `error`) es una orden explícita del operador, así que
  # también reintenta las filas `failed` — se arregló el chat y el mensaje debe
  # salir.
  defp manual_resend?(%Notification{status: "pending", error: nil}), do: true
  defp manual_resend?(_notification), do: false

  # Un resultado por destino: `{:sent, link, message_id}`,
  # `{:pending, link, reason}` (transitorio) o `{:failed, link, reason}`
  # (terminal).
  defp finalize(notification, outcomes) do
    pending = for {:pending, link, reason} <- outcomes, do: {link, reason}
    failed = for {:failed, link, reason} <- outcomes, do: {link, reason}
    sent = for {:sent, link, message_id} <- outcomes, do: {link, message_id}

    cond do
      pending != [] ->
        reason = join_reasons(pending)
        mark(notification, %{status: "pending", error: reason})
        {:error, reason}

      sent != [] ->
        {_link, message_id} = List.first(sent)

        mark(notification, %{
          status: "sent",
          telegram_message_id: message_id,
          sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
          error: failed_message(failed)
        })

        :ok

      true ->
        reason = join_reasons(failed)
        mark(notification, %{status: "failed", error: reason})
        {:discard, reason}
    end
  end

  # Una fila de progreso por (notificación, link). Idempotente: el reintento
  # encuentra la fila del intento anterior y respeta su estado.
  defp deliver_to(notification, link, text, opts) do
    delivery = ensure_delivery(notification, link)
    retry_terminal? = Keyword.get(opts, :retry_terminal, false)

    cond do
      delivery.status == "sent" ->
        {:sent, link, delivery.telegram_message_id}

      delivery.status == "failed" and not retry_terminal? ->
        {:failed, link, delivery.error || "previously rejected"}

      true ->
        case Telegram.send_message(link.chat_id, text, thread_opts(link)) do
          {:ok, message_id} ->
            update_delivery(delivery, %{
              status: "sent",
              telegram_message_id: message_id,
              sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
              error: nil
            })

            {:sent, link, message_id}

          {:discard, reason} ->
            update_delivery(delivery, %{status: "failed", error: reason})
            {:failed, link, reason}

          {:error, reason} ->
            update_delivery(delivery, %{status: "pending", error: reason})
            {:pending, link, reason}
        end
    end
  end

  defp ensure_delivery(notification, link) do
    case Repo.get_by(Delivery, notification_id: notification.id, link_id: link.id) do
      nil ->
        %Delivery{}
        |> Delivery.changeset(%{
          notification_id: notification.id,
          link_id: link.id,
          chat_id: link.chat_id,
          thread_id: link.thread_id
        })
        |> Repo.insert()
        |> case do
          {:ok, delivery} ->
            delivery

          # Carrera con otra fila del mismo par (should not happen: Oban no
          # ejecuta el mismo job en paralelo), pero el índice único manda.
          {:error, _changeset} ->
            Repo.get_by!(Delivery, notification_id: notification.id, link_id: link.id)
        end

      delivery ->
        delivery
    end
  end

  defp update_delivery(delivery, attrs) do
    attrs = Map.put(attrs, :attempts, delivery.attempts + 1)

    case delivery
         |> Delivery.changeset(attrs)
         |> Repo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error(
          "notifications: delivery progress update failed: #{inspect(changeset.errors)}"
        )

        delivery
    end
  end

  defp join_reasons(reasons) do
    reasons
    |> Enum.map(fn {%{chat_id: chat_id}, reason} -> "#{chat_id}: #{reason}" end)
    |> Enum.join("; ")
  end

  # Los rechazos terminales no bloquean el `sent` global (otros chats sí
  # recibieron), pero quedan visibles en `error` para Operaciones.
  defp failed_message([]), do: nil

  defp failed_message(failed) do
    failed
    |> Enum.map(fn {%{chat_id: chat_id}, reason} -> "not delivered to #{chat_id}: #{reason}" end)
    |> Enum.join("; ")
  end

  defp thread_opts(%{thread_id: nil}), do: []
  defp thread_opts(%{thread_id: thread_id}), do: [message_thread_id: thread_id]

  @doc "Renders the Telegram text for a notification (also used by the preview)."
  @spec render(Notification.t()) :: String.t()
  def render(%Notification{} = notification) do
    event = safe_event(notification.event)
    attrs = Map.merge(notification.payload || %{}, %{target_label: notification.target_label})
    {title, body} = Events.message(event, attrs)

    case body do
      "" -> "#{emoji(notification.severity)} #{title}"
      _ -> "#{emoji(notification.severity)} #{title}\n\n#{body}"
    end
  end

  defp safe_event(name) do
    String.to_existing_atom(name)
  rescue
    _ -> :unknown
  end

  defp emoji("critical"), do: "🔴"
  defp emoji("warning"), do: "🟡"
  defp emoji("security"), do: "🔐"
  defp emoji(_), do: "🔵"

  defp mark(notification, attrs) do
    case notification
         |> Notification.changeset(attrs)
         |> Repo.update() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error("notifications: mark failed: #{inspect(changeset.errors)}")
    end
  end
end
