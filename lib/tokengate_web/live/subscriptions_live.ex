defmodule TokengateWeb.SubscriptionsLive do
  @moduledoc """
  Admin-only CRUD for credit subscriptions.

  Una suscripción otorga `units` de crédito por ciclo. Es o bien un **default de
  grupo** (uno o más grupos la referencian) o el **crédito directo** de un
  usuario (incluye top-ups, `recurrence = "none"`).

  Listado en tabla compacta (búsqueda en header, columnas ordenables, stream y
  modal) — mismo patrón que Proveedores / Servicios.
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Credits
  alias Tokengate.Credits.Subscription

  @sort_columns ~w(target units recurrence reset_day rollover status inserted_at)a

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
        |> assign(:show_archived, false)
        |> assign(:archived_ids, MapSet.new())
        |> assign(:archived_count, 0)
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

    {archived_ids, archived_count} =
      assigns.all_subscriptions
      |> Enum.filter(&expired_or_drained?/1)
      |> (&{MapSet.new(&1, fn sub -> sub.id end), length(&1)}).()

    filtered =
      Enum.filter(assigns.all_subscriptions, fn sub ->
        (socket.assigns.show_archived or sub.id not in archived_ids) and
          (search == "" or
             String.contains?(String.downcase(target_label(sub, assigns)), search_down) or
             String.contains?(String.downcase(sub.name || ""), search_down))
      end)

    sorted = sort_subscriptions(filtered, assigns.sort_field, assigns.sort_direction, assigns)

    socket
    |> assign(:archived_ids, archived_ids)
    |> assign(:archived_count, archived_count)
    |> stream(:subscriptions, sorted, reset: true)
    |> assign(:subscriptions_empty?, filtered == [])
    |> assign(:usage_by_sub, usage_by_sub(filtered))
  end

  # Auto-archivables: top-ups (`recurrence = "none"`) vencidos (su `expires_at`
  # ya pasó) o agotados (todo el crédito del grant fue consumido). Las subs
  # mensuales se reciclan cada ciclo, así que nunca se auto-archivan.
  defp expired_or_drained?(%Subscription{recurrence: "none"} = sub) do
    now = DateTime.utc_now()

    expired? =
      sub.expires_at != nil and DateTime.compare(sub.expires_at, now) != :gt

    drained? =
      sub.units > 0 and sub.units * 1_000_000 <= Credits.lifetime_spend_micro(sub.id)

    expired? or drained?
  end

  defp expired_or_drained?(%Subscription{}), do: false

  # Consumo del ciclo vigente por suscripción (para la columna "Consumo").
  # La lista es acotada; una query SUM por sub es suficiente.
  defp usage_by_sub(subs) do
    Map.new(subs, fn sub ->
      usage = Credits.subscription_usage(sub)
      {sub.id, {usage, sub}}
    end)
  end

  ## Events — search / sort -------------------------------------------------

  @impl true
  def handle_event("search_subscriptions", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> stream_subscriptions()}
  end

  def handle_event("sort_subscriptions", %{"field" => field}, socket) do
    with {:ok, field} <- to_sort_field(field),
         true <- field in @sort_columns do
      {sort_field, sort_direction} =
        if socket.assigns.sort_field == field do
          {field, toggle_sort_direction(socket.assigns.sort_direction)}
        else
          {field, default_direction_for(field)}
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

  def handle_event("toggle_archived", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_archived, not socket.assigns.show_archived)
     |> stream_subscriptions()}
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
     |> assign(:sub_users, user_tag(socket.assigns.users, subscription.user_id))
     |> assign(:sub_user_query, "")
     |> assign(:sub_user_results, [])}
  end

  def handle_event("cancel_subscription", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:editing_subscription_id, nil)}
  end

  def handle_event("sub_form_change", params, socket) do
    scope = params["scope"] || socket.assigns.sub_scope
    query = params["sub_user_query"] || ""

    results =
      if scope == "user" and is_binary(query) and String.trim(query) != "" do
        selected_ids = Enum.map(socket.assigns.sub_users, & &1.id)

        query
        |> String.trim()
        |> Accounts.search_users(25)
        |> Enum.reject(&(&1.id in selected_ids))
      else
        []
      end

    {:noreply,
     socket
     |> assign(:sub_scope, scope)
     |> assign(:sub_user_query, query)
     |> assign(:sub_user_results, results)}
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

  defp user_tag(_users, nil), do: []

  defp user_tag(users, user_id) do
    case Enum.find(users, &(&1.id == user_id)) do
      nil -> [%{id: user_id, label: "Usuario"}]
      u -> [%{id: user_id, label: u.name || u.email}]
    end
  end

  ## Sorting ----------------------------------------------------------------

  defp sort_subscriptions(subs, field, direction, assigns) do
    Enum.sort_by(subs, &sort_value(&1, field, assigns), fn a, b ->
      if direction == :asc, do: compare_vals(a, b) != :gt, else: compare_vals(a, b) != :lt
    end)
  end

  defp sort_value(sub, :target, assigns), do: String.downcase(target_label(sub, assigns))
  defp sort_value(sub, :units, _assigns), do: sub.units
  defp sort_value(sub, :recurrence, _assigns), do: sub.recurrence || ""
  defp sort_value(sub, :reset_day, _assigns), do: sub.reset_day || 0
  defp sort_value(sub, :rollover, _assigns), do: sub.rollover_mode || ""
  defp sort_value(sub, :status, _assigns), do: sub.status || ""
  defp sort_value(sub, :inserted_at, _assigns), do: sub.inserted_at

  defp compare_vals(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)

  defp compare_vals(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  ## Template helpers -------------------------------------------------------

  @doc "Etiqueta del objetivo: los grupos (default) o el usuario directo."
  def target_label(sub, assigns) do
    case Map.get(assigns.groups_by_sub || %{}, sub.id, []) do
      [] ->
        if sub.user_id do
          case Enum.find(assigns.users, &(&1.id == sub.user_id)) do
            nil -> "Usuario"
            u -> "Usuario: #{u.name || u.email}"
          end
        else
          "Sin grupo asignado"
        end

      groups ->
        Enum.map_join(groups, ", ", & &1.name)
    end
  end

  # ¿Esta sub está auto-archivada en el listado vigente?
  def archived?(%Subscription{} = sub, assigns),
    do: MapSet.member?(assigns.archived_ids, sub.id)

  def archived_reason(%Subscription{} = sub, _assigns) do
    expired? =
      is_struct(sub.expires_at, DateTime) and
        DateTime.compare(sub.expires_at, DateTime.utc_now()) != :gt

    drained? =
      sub.units > 0 and sub.units * 1_000_000 <= Credits.lifetime_spend_micro(sub.id)

    cond do
      expired? -> "Vencida"
      drained? -> "Agotada"
      true -> "Archivada"
    end
  end

  def recurrence_label("monthly"), do: "Mensual"
  def recurrence_label("none"), do: "Top-up"
  def recurrence_label(other), do: other || "—"

  def rollover_label(%{rollover_mode: "rollover", rollover_pct: pct, rollover_cap_units: cap}) do
    "#{pct}%" <> if(cap, do: " (tope #{cap})", else: "")
  end

  def rollover_label(_), do: "Se pierde"

  # --- Consumo (columna "Consumo") -------------------------------------------

  # "%{credited_micro, consumed_micro}" → "X / Y (Z%)" en créditos
  # (micro-USD → USD; 1 crédito = $1). "—" cuando la sub no otorga crédito.
  def usage_label(%{credited_micro: 0}, _sub), do: "—"

  def usage_label(%{consumed_micro: consumed_micro}, sub) do
    used =
      Decimal.new(consumed_micro)
      |> Decimal.div(Decimal.new(1_000_000))
      |> Decimal.round(2)

    allocated = Decimal.new(sub.units)

    cond do
      Decimal.compare(used, allocated) == :gt ->
        "#{used} / #{allocated} (excedido)"

      Decimal.compare(allocated, 0) == :eq ->
        "#{used} / 0"

      true ->
        pct = Decimal.mult(Decimal.div(used, allocated), 100) |> Decimal.round(0)
        "#{used} / #{allocated} (#{pct}%)"
    end
  end

  # Celda de la columna "Consumo": label + barra de progreso (colores del
  # dashboard: verde < 70%, ámbar < 90%, rojo ≥ 90%).
  def render_usage_cell(sub, assigns) do
    assigns =
      case Map.get(assigns.usage_by_sub, sub.id) do
        nil -> %{usage: nil, sub: sub}
        {usage, sub} -> %{usage: usage, sub: sub}
      end

    assigns = Map.put(assigns, :label, usage_label(assigns.usage || %{credited_micro: 0}, sub))

    assigns =
      Map.put(
        assigns,
        :pct,
        case assigns.usage do
          nil -> nil
          %{credited_micro: 0} -> nil
          %{credited_micro: c, consumed_micro: k} -> Float.round(k / c * 100, 1)
        end
      )

    assigns =
      Map.put(
        assigns,
        :bar_class,
        cond do
          is_nil(assigns.pct) -> "bg-base-300"
          assigns.pct >= 90 -> "bg-error"
          assigns.pct >= 70 -> "bg-warning"
          true -> "bg-success"
        end
      )

    assigns =
      Map.put(
        assigns,
        :width,
        if(is_nil(assigns.pct), do: "width: 0%", else: "width: #{min(assigns.pct, 100)}%")
      )

    ~H"""
    <div class="text-xs font-mono">{@label}</div>
    <div class="mt-1 h-1.5 rounded-full bg-base-200 overflow-hidden">
      <div class={["h-full rounded-full transition-all", @bar_class]} style={@width}></div>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :current, :atom, required: true
  attr :direction, :atom, required: true
  attr :align, :string, default: "left"

  defp sort_button(assigns) do
    ~H"""
    <button
      phx-click="sort_subscriptions"
      phx-value-field={@field}
      class={[
        "flex items-center gap-1 hover:text-primary",
        @align == "right" && "justify-end w-full"
      ]}
      id={"sort-#{@field}"}
    >
      {@label}
      <span class="inline-block w-3 text-center">
        <%= if @current == @field do %>
          {if @direction == :asc, do: "▲", else: "▼"}
        <% end %>
      </span>
    </button>
    """
  end

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  defp toggle_sort_direction(:asc), do: :desc
  defp toggle_sort_direction(:desc), do: :asc

  defp default_direction_for(field) when field in [:units, :inserted_at], do: :desc
  defp default_direction_for(_), do: :asc
end
