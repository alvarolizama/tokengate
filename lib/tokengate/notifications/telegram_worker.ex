defmodule Tokengate.Notifications.TelegramWorker do
  @moduledoc """
  Oban worker que entrega una `Notification` a todos los chats vinculados.

  ## Retry semantics

    * todos los envíos `2xx` → `:ok` y la notificación pasa a `sent`;
    * rechazo del destino (4xx / `ok:false`) → `{:discard, _}` y queda `failed`;
    * error de transporte o 5xx → `{:error, _}` — Oban reintenta con backoff.

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

        results =
          Enum.map(targets, &{&1, Telegram.send_message(&1.chat_id, text, thread_opts(&1))})

        cond do
          Enum.any?(results, fn {_id, res} -> match?({:ok, _}, res) end) ->
            {:ok, message_id} =
              Enum.find_value(results, fn
                {_id, {:ok, mid}} -> {:ok, mid}
                _ -> nil
              end)

            mark(notification, %{
              status: "sent",
              telegram_message_id: message_id,
              sent_at: DateTime.utc_now(),
              error: nil
            })

            :ok

          Enum.all?(results, fn {_id, res} -> match?({:discard, _}, res) end) ->
            reason = results |> Enum.map(fn {_id, {:discard, r}} -> r end) |> Enum.join("; ")
            mark(notification, %{status: "failed", error: reason})
            {:discard, reason}

          true ->
            reason =
              results
              |> Enum.map(fn
                {_target, {:error, r}} -> r
                {%{chat_id: chat_id}, {:discard, r}} -> "#{chat_id}: #{r}"
                _ -> "unknown"
              end)
              |> Enum.join("; ")

            mark(notification, %{status: "failed", error: reason})
            {:error, reason}
        end
    end
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
