defmodule TokengateWeb.TopupsLive do
  @moduledoc """
  Admin-only CRUD for top-ups — crédito de una sola vez por usuario.

  Un top-up es una suscripción con `recurrence = "none"` y dueño directo
  (`user_id`): otorga `units` de crédito hasta agotarse o vencer. La tabla
  muestra **cuánto se consumió de lo otorgado** (columna Consumo) y los
  top-ups se auto-archivan cuando el remanente llega a **0** (agotado) o
  cuando **vencen**; el toggle "Ver archivados" los revela con su badge.

  Acciones por fila:

    * **Desactivar / Reactivar** — pausa: deja de otorgar el saldo restante
      (lo ya consumido queda visible) y se puede reactivar.
    * **Revocar** — elimina el top-up completo; el consumo ya asentado queda
      en los logs.

  Las suscripciones recurrentes viven en `/credit/subscriptions`.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Credits
  alias Tokengate.Credits.Subscription
  alias TokengateWeb.CreditHelpers, as: Credit

  import TokengateWeb.CreditHelpers, only: [sort_button: 1]

  @sort_columns ~w(target units expires_at status inserted_at)a

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, "No tienes permisos para acceder a esta sección.")
       |> redirect(to: "/dashboard")}
    else
      socket =
        socket
        |> assign(:page_title, "Top-ups · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> stream_configure(:topups, dom_id: &"topup-#{&1.id}")
        |> assign(:form, nil)
        |> assign(:editing_topup_id, nil)
        |> assign(:topup_users, [])
        |> assign(:topup_user_query, "")
        |> assign(:topup_user_results, [])
        |> assign(:topup_expires_on, "")
        |> assign(:search_query, "")
        |> assign(:sort_field, :inserted_at)
        |> assign(:sort_direction, :desc)
        |> assign(:show_archived, false)
        |> assign(:archived_ids, MapSet.new())
        |> assign(:archived_count, 0)
        |> load_topups()

      {:ok, socket}
    end
  end

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Data loading -----------------------------------------------------------

  defp load_topups(socket) do
    socket
    |> assign(:all_topups, Credits.list_subscriptions())
    |> assign(:groups_by_sub, Credits.groups_by_subscription())
    |> assign(:users, Accounts.list_users())
    |> stream_topups()
  end

  defp stream_topups(socket) do
    search = socket.assigns[:search_query] || ""
    search_down = String.downcase(search)
    assigns = socket.assigns

    # Solo top-ups: las subs recurrentes viven en /credit/subscriptions.
    topups = Enum.filter(assigns.all_topups, &(&1.recurrence == "none"))

    {archived_ids, archived_count} =
      topups
      |> Enum.filter(&Credit.expired_or_drained?/1)
      |> (&{MapSet.new(&1, fn sub -> sub.id end), length(&1)}).()

    filtered =
      Enum.filter(topups, fn sub ->
        (assigns.show_archived or sub.id not in archived_ids) and
          (search == "" or
             String.contains?(String.downcase(Credit.target_label(sub, assigns)), search_down) or
             String.contains?(String.downcase(sub.name || ""), search_down))
      end)

    sorted =
      Credit.sort_rows(
        filtered,
        assigns.sort_direction,
        &sort_value(&1, assigns.sort_field, assigns)
      )

    socket
    |> assign(:archived_ids, archived_ids)
    |> assign(:archived_count, archived_count)
    |> stream(:topups, sorted, reset: true)
    |> assign(:topups_empty?, filtered == [])
    |> assign(:usage_by_sub, Credit.usage_by_sub(filtered))
  end

  ## Events — search / sort / archivo ---------------------------------------

  @impl true
  def handle_event("search_topups", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> stream_topups()}
  end

  def handle_event("sort_topups", %{"field" => field}, socket) do
    with {:ok, field} <- Credit.to_sort_field(field),
         true <- field in @sort_columns do
      {sort_field, sort_direction} =
        if socket.assigns.sort_field == field do
          {field, Credit.toggle_sort_direction(socket.assigns.sort_direction)}
        else
          {field, Credit.default_direction_for(field, [:units, :inserted_at])}
        end

      {:noreply,
       socket
       |> assign(:sort_field, sort_field)
       |> assign(:sort_direction, sort_direction)
       |> stream_topups()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_archived, not socket.assigns.show_archived)
     |> stream_topups()}
  end

  ## Events — CRUD ----------------------------------------------------------

  def handle_event("new_topup", _params, socket) do
    {:noreply,
     socket
     |> assign(
       :form,
       to_form(
         Credits.change_subscription(%Subscription{recurrence: "none"}),
         as: :subscription
       )
     )
     |> assign(:editing_topup_id, :new)
     |> assign(:topup_users, [])
     |> assign(:topup_user_query, "")
     |> assign(:topup_user_results, [])
     |> assign(:topup_expires_on, "")}
  end

  def handle_event("edit_topup", %{"id" => id}, socket) do
    topup = Credits.get_subscription!(id)

    {:noreply,
     socket
     |> assign(:form, to_form(Credits.change_subscription(topup), as: :subscription))
     |> assign(:editing_topup_id, topup.id)
     |> assign(:topup_users, Credit.user_tag(socket.assigns.users, topup.user_id))
     |> assign(:topup_user_query, "")
     |> assign(:topup_user_results, [])
     |> assign(:topup_expires_on, format_expires_on(topup.expires_at))}
  end

  def handle_event("cancel_topup", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:editing_topup_id, nil)}
  end

  # Desactivar/reactivar: pausar deja de otorgar el saldo restante (lo ya
  # consumido sigue visible en la columna Consumo) hasta reactivar.
  def handle_event("toggle_topup_status", %{"id" => id}, socket) do
    topup = Credits.get_subscription!(id)
    pausing? = topup.status == "active"
    new_status = if pausing?, do: "paused", else: "active"

    case Credits.update_subscription(topup, %{"status" => new_status}) do
      {:ok, _} ->
        message =
          if pausing?,
            do: "Top-up desactivado — el saldo restante deja de otorgarse.",
            else: "Top-up reactivado."

        {:noreply, socket |> load_topups() |> put_flash(:info, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo cambiar el estado del top-up.")}
    end
  end

  # Revocar: elimina el top-up completo. El consumo ya asentado queda en los
  # logs (`request_logs.credit_subscription_id`, sin FK) y el vínculo de
  # grupos se limpia solo (`on_delete: :nilify_all`).
  def handle_event("revoke_topup", %{"id" => id}, socket) do
    topup = Credits.get_subscription!(id)
    Credits.assign_groups(topup, [])
    Credits.delete_subscription(topup)

    {:noreply, socket |> load_topups() |> put_flash(:info, "Top-up revocado.")}
  end

  def handle_event("topup_form_change", params, socket) do
    query = params["topup_user_query"] || ""
    expires_on = Map.get(params, "topup_expires_on", socket.assigns.topup_expires_on)
    selected_ids = Enum.map(socket.assigns.topup_users, & &1.id)

    {:noreply,
     socket
     |> assign(:topup_user_query, query)
     |> assign(:topup_user_results, Credit.users_search(query, selected_ids))
     |> assign(:topup_expires_on, expires_on || "")}
  end

  def handle_event("add_topup_user", %{"user-id" => user_id} = params, socket) do
    if Enum.any?(socket.assigns.topup_users, &(&1.id == user_id)) do
      {:noreply, socket}
    else
      label = params["label"] || user_id

      {:noreply,
       socket
       |> assign(:topup_users, socket.assigns.topup_users ++ [%{id: user_id, label: label}])
       |> assign(:topup_user_query, "")
       |> assign(:topup_user_results, [])}
    end
  end

  def handle_event("remove_topup_user", %{"user-id" => user_id}, socket) do
    {:noreply,
     assign(socket, :topup_users, Enum.reject(socket.assigns.topup_users, &(&1.id == user_id)))}
  end

  def handle_event("save_topup", params, socket) do
    sub_params = params["subscription"] || %{}
    editing = socket.assigns.editing_topup_id

    if socket.assigns.topup_users == [] do
      {:noreply, put_flash(socket, :error, "Selecciona al menos un usuario.")}
    else
      expires_on = Map.get(params, "topup_expires_on", socket.assigns.topup_expires_on)

      attrs =
        sub_params
        |> Map.put("recurrence", "none")
        |> Map.put("expires_at", parse_expires_on(expires_on))

      [first | rest] = Enum.map(socket.assigns.topup_users, & &1.id)

      result =
        if is_binary(editing) do
          case Credits.update_subscription(
                 Credits.get_subscription!(editing),
                 Map.put(attrs, "user_id", first)
               ) do
            {:ok, _} -> create_topups(rest, attrs)
            {:error, changeset} -> {:error, changeset}
          end
        else
          create_topups([first | rest], attrs)
        end

      case result do
        :ok ->
          {:noreply,
           socket
           |> assign(:form, nil)
           |> assign(:editing_topup_id, nil)
           |> load_topups()
           |> put_flash(:info, "Top-up guardado.")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :subscription))}
      end
    end
  end

  # Un top-up por usuario seleccionado (mismo patrón que las subs directas).
  defp create_topups(user_ids, attrs) do
    Enum.reduce_while(user_ids, :ok, fn uid, :ok ->
      case Credits.create_subscription(Map.put(attrs, "user_id", uid)) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  ## Fechas ----------------------------------------------------------------

  # El campo "Vence" es un `<input type="date">` (YYYY-MM-DD). Se guarda al
  # FINAL del día (23:59:59 UTC) para que el top-up valga todo ese día:
  # `Credits.expired?/1` compara `expires_at <= now`. Vacío = sin vencimiento.
  defp parse_expires_on(nil), do: nil

  defp parse_expires_on(value) when is_binary(value) do
    case value |> String.trim() |> Date.from_iso8601() do
      {:ok, date} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp format_expires_on(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
  defp format_expires_on(_), do: ""

  defp expires_label(nil), do: "—"
  defp expires_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y")

  ## Sorting ----------------------------------------------------------------

  defp sort_value(sub, :target, assigns), do: String.downcase(Credit.target_label(sub, assigns))
  defp sort_value(sub, :units, _assigns), do: sub.units
  defp sort_value(sub, :expires_at, _assigns), do: sub.expires_at
  defp sort_value(sub, :status, _assigns), do: sub.status || ""
  defp sort_value(sub, :inserted_at, _assigns), do: sub.inserted_at
end
