defmodule TokengateWeb.SubscriptionsLive do
  @moduledoc """
  Admin-only CRUD for credit subscriptions.

  Una suscripción otorga `units` de crédito por ciclo y es **recurrente**
  (mensual, anclada en `reset_day`). Es o bien un **default de grupo** (uno o
  más grupos la referencian) o el **crédito directo** de un usuario.

  Los **top-ups** (crédito de una sola vez, `recurrence = "none"`) viven en su
  propia página: `/credit/topups` — mismo modelo, otra vista.

  Listado en tabla compacta (búsqueda en header, columnas ordenables, stream y
  modal) — mismo patrón que Proveedores / Servicios. Cada fila se puede
  **desactivar** (pausa: deja de otorgar crédito hasta reactivarla) o eliminar.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Credits
  alias Tokengate.Credits.Subscription
  alias TokengateWeb.CreditHelpers, as: Credit

  import TokengateWeb.CreditHelpers, only: [sort_button: 1]

  @sort_columns ~w(target units reset_day rollover status inserted_at)a

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
        |> assign(:page_title, "Suscripciones · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> stream_configure(:subscriptions, dom_id: &"subscription-#{&1.id}")
        |> assign(:form, nil)
        |> assign(:editing_subscription_id, nil)
        |> assign(:sub_scope, "group")
        |> assign(:sub_group_ids, [])
        |> assign(:sub_users, [])
        |> assign(:sub_user_query, "")
        |> assign(:sub_user_results, [])
        |> assign(:search_query, "")
        |> assign(:sort_field, :target)
        |> assign(:sort_direction, :asc)
        |> load_subscriptions()

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

  defp load_subscriptions(socket) do
    socket
    |> assign(:all_subscriptions, Credits.list_subscriptions())
    |> assign(:groups_by_sub, Credits.groups_by_subscription())
    |> assign(:groups, Accounts.list_groups())
    |> assign(:users, Accounts.list_users())
    |> stream_subscriptions()
  end

  defp stream_subscriptions(socket) do
    search = socket.assigns[:search_query] || ""
    search_down = String.downcase(search)
    assigns = socket.assigns

    # Solo recurrentes: los top-ups viven en /credit/topups.
    subscriptions = Enum.filter(assigns.all_subscriptions, &(&1.recurrence == "monthly"))

    filtered =
      Enum.filter(subscriptions, fn sub ->
        search == "" or
          String.contains?(String.downcase(Credit.target_label(sub, assigns)), search_down) or
          String.contains?(String.downcase(sub.name || ""), search_down)
      end)

    sorted =
      Credit.sort_rows(
        filtered,
        assigns.sort_direction,
        &sort_value(&1, assigns.sort_field, assigns)
      )

    socket
    |> stream(:subscriptions, sorted, reset: true)
    |> assign(:subscriptions_empty?, filtered == [])
    |> assign(:usage_by_sub, Credit.usage_by_sub(filtered))
  end

  ## Events — search / sort -------------------------------------------------

  @impl true
  def handle_event("search_subscriptions", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> stream_subscriptions()}
  end

  def handle_event("sort_subscriptions", %{"field" => field}, socket) do
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
       |> stream_subscriptions()}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Events — CRUD ----------------------------------------------------------

  def handle_event("new_subscription", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(Credits.change_subscription(%Subscription{}), as: :subscription))
     |> assign(:editing_subscription_id, :new)
     |> assign(:sub_scope, "group")
     |> assign(:sub_group_ids, [])
     |> assign(:sub_users, [])
     |> assign(:sub_user_query, "")
     |> assign(:sub_user_results, [])}
  end

  def handle_event("edit_subscription", %{"id" => id}, socket) do
    subscription = Credits.get_subscription!(id)
    scope = if subscription.user_id, do: "user", else: "group"

    {:noreply,
     socket
     |> assign(:form, to_form(Credits.change_subscription(subscription), as: :subscription))
     |> assign(:editing_subscription_id, subscription.id)
     |> assign(:sub_scope, scope)
     |> assign(:sub_group_ids, Credits.group_ids_for(subscription))
     |> assign(:sub_users, Credit.user_tag(socket.assigns.users, subscription.user_id))
     |> assign(:sub_user_query, "")
     |> assign(:sub_user_results, [])}
  end

  def handle_event("cancel_subscription", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:editing_subscription_id, nil)}
  end

  # Desactivar/reactivar desde la tabla: pausar deja de otorgar crédito
  # (grant con 0) hasta reactivar — sin abrir el modal.
  def handle_event("toggle_subscription_status", %{"id" => id}, socket) do
    subscription = Credits.get_subscription!(id)
    pausing? = subscription.status == "active"
    new_status = if pausing?, do: "paused", else: "active"

    case Credits.update_subscription(subscription, %{"status" => new_status}) do
      {:ok, _} ->
        message =
          if pausing?,
            do: "Suscripción desactivada — deja de otorgar crédito.",
            else: "Suscripción reactivada."

        {:noreply, socket |> load_subscriptions() |> put_flash(:info, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo cambiar el estado de la suscripción.")}
    end
  end

  def handle_event("sub_form_change", params, socket) do
    scope = params["scope"] || socket.assigns.sub_scope
    query = params["sub_user_query"] || ""
    selected_ids = Enum.map(socket.assigns.sub_users, & &1.id)

    {:noreply,
     socket
     |> assign(:sub_scope, scope)
     |> assign(:sub_user_query, query)
     |> assign(:sub_user_results, Credit.users_search(query, selected_ids))}
  end

  def handle_event("add_sub_user", %{"user-id" => user_id} = params, socket) do
    if Enum.any?(socket.assigns.sub_users, &(&1.id == user_id)) do
      {:noreply, socket}
    else
      label = params["label"] || user_id

      {:noreply,
       socket
       |> assign(:sub_users, socket.assigns.sub_users ++ [%{id: user_id, label: label}])
       |> assign(:sub_user_query, "")
       |> assign(:sub_user_results, [])}
    end
  end

  def handle_event("remove_sub_user", %{"user-id" => user_id}, socket) do
    {:noreply,
     assign(socket, :sub_users, Enum.reject(socket.assigns.sub_users, &(&1.id == user_id)))}
  end

  def handle_event("save_subscription", params, socket) do
    scope = params["scope"] || "group"
    sub_params = params["subscription"] || %{}
    editing = socket.assigns.editing_subscription_id

    # Esta página es la de subs recurrentes: la recurrencia se fija aquí (el
    # modal ya no la ofrece) y el alcance decide el resto.
    sub_params = Map.put(sub_params, "recurrence", "monthly")

    cond do
      scope == "user" and socket.assigns.sub_users == [] ->
        {:noreply, put_flash(socket, :error, "Selecciona al menos un usuario.")}

      scope == "user" ->
        user_ids = Enum.map(socket.assigns.sub_users, & &1.id)

        case save_user_subscriptions(editing, sub_params, user_ids) do
          :ok -> {:noreply, finish_save(socket, "user")}
          {:error, changeset} -> {:noreply, fail_save(socket, "user", changeset)}
        end

      true ->
        attrs = Map.put(sub_params, "user_id", nil)

        case persist_group_subscription(editing, attrs) do
          {:ok, subscription} ->
            Credits.assign_groups(subscription, Map.get(params, "group_ids", []))
            {:noreply, finish_save(socket, "group")}

          {:error, changeset} ->
            {:noreply, fail_save(socket, "group", changeset)}
        end
    end
  end

  def handle_event("delete_subscription", %{"id" => id}, socket) do
    subscription = Credits.get_subscription!(id)
    Credits.assign_groups(subscription, [])
    Credits.delete_subscription(subscription)

    {:noreply, socket |> load_subscriptions() |> put_flash(:info, "Suscripción eliminada.")}
  end

  defp persist_group_subscription(:new, attrs), do: Credits.create_subscription(attrs)

  defp persist_group_subscription(id, attrs) when is_binary(id) do
    Credits.update_subscription(Credits.get_subscription!(id), attrs)
  end

  defp finish_save(socket, scope) do
    socket
    |> assign(:sub_scope, scope)
    |> assign(:form, nil)
    |> assign(:editing_subscription_id, nil)
    |> load_subscriptions()
    |> put_flash(:info, "Suscripción guardada.")
  end

  defp fail_save(socket, scope, changeset) do
    socket
    |> assign(:sub_scope, scope)
    |> assign(:form, to_form(changeset, as: :subscription))
  end

  # User scope: una suscripción por usuario seleccionado. Al editar una sub
  # existente, se actualiza al primer usuario y se crean para el resto.
  defp save_user_subscriptions(editing, sub_params, user_ids) do
    if is_binary(editing) do
      [first | rest] = user_ids

      case Credits.update_subscription(
             Credits.get_subscription!(editing),
             Map.put(sub_params, "user_id", first)
           ) do
        {:ok, _} -> create_user_subs(rest, sub_params)
        {:error, changeset} -> {:error, changeset}
      end
    else
      create_user_subs(user_ids, sub_params)
    end
  end

  defp create_user_subs(user_ids, sub_params) do
    Enum.reduce_while(user_ids, :ok, fn uid, :ok ->
      case Credits.create_subscription(Map.put(sub_params, "user_id", uid)) do
        {:ok, _} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  ## Template helpers -------------------------------------------------------

  defp rollover_label(%{rollover_mode: "rollover", rollover_pct: pct, rollover_cap_units: cap}) do
    "#{pct}%" <> if(cap, do: " (tope #{cap})", else: "")
  end

  defp rollover_label(_), do: "Se pierde"

  ## Sorting ----------------------------------------------------------------

  defp sort_value(sub, :target, assigns), do: String.downcase(Credit.target_label(sub, assigns))
  defp sort_value(sub, :units, _assigns), do: sub.units
  defp sort_value(sub, :reset_day, _assigns), do: sub.reset_day || 0
  defp sort_value(sub, :rollover, _assigns), do: sub.rollover_mode || ""
  defp sort_value(sub, :status, _assigns), do: sub.status || ""
  defp sort_value(sub, :inserted_at, _assigns), do: sub.inserted_at
end
