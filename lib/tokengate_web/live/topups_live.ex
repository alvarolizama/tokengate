defmodule TokengateWeb.TopupsLive do
  @moduledoc """
  Admin-only CRUD de **top-ups**: crédito extra de un solo uso.

  Un top-up pertenece a un **usuario** o a un **servicio** (exactamente uno) y
  otorga `amount_usd` hasta agotarse o vencer; `expires_in_days` nil = nunca
  vence. Es el segundo camino de gasto de un sujeto con límite mensual, y el
  único para uno que no lo tiene.

  La tabla muestra cuánto se consumió de lo otorgado (medido contra
  `request_logs.credit_topup_id`) y archiva —sin borrar— los vencidos y
  agotados; el toggle "Ver archivados" los revela con su badge.

  Acciones por fila:

    * **Desactivar / Reactivar** — deja de otorgar el saldo restante (lo ya
      consumido queda en los logs) y se puede reactivar.
    * **Revocar** — marca el top-up como revocado; deja de otorgar.

  Esta es la **única** página de crédito: las suscripciones desaparecieron del
  modelo y el gasto ordinario se gobierna con el límite mensual de cada sujeto
  (se edita en su propia página de Acceso).
  """

  use TokengateWeb, :live_view

  alias Tokengate.Accounts
  alias Tokengate.Credits.{Topup, Topups}

  import TokengateWeb.TopupHelpers

  @sort_columns ~w(target amount expires_at status inserted_at)a

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
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
        |> assign(:owner_kind, "user")
        |> assign(:owner_query, "")
        |> assign(:owner_results, [])
        |> assign(:selected_owner, nil)
        |> assign(:search_query, "")
        |> assign(:sort_field, :inserted_at)
        |> assign(:sort_direction, :desc)
        |> assign(:show_archived, false)
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
    topups = Topups.list_all()
    archived = Enum.filter(topups, &archived?/1)

    socket
    |> assign(:archived_count, length(archived))
    |> assign(:all_topups, topups)
    |> assign(:topups_empty?, visible_topups(topups, socket) == [])
    |> stream(:topups, visible_topups(topups, socket), reset: true)
  end

  defp visible_topups(topups, socket) do
    assigns = socket.assigns

    topups
    |> Enum.filter(fn t -> assigns.show_archived || not archived?(t) end)
    |> filter_by_query(assigns.search_query)
    |> sort(assigns.sort_field, assigns.sort_direction)
  end

  defp filter_by_query(topups, ""), do: topups

  defp filter_by_query(topups, query) do
    q = String.downcase(query)

    Enum.filter(topups, fn t ->
      String.contains?(String.downcase(owner_label(t)), q) or
        String.contains?(String.downcase(t.label || ""), q)
    end)
  end

  defp sort(topups, field, direction) do
    sorted =
      Enum.sort_by(topups, fn t ->
        case field do
          :target -> owner_label(t)
          :amount -> Decimal.to_float(t.amount_usd)
          :expires_at -> t.expires_at || ~U[9999-12-31 00:00:00Z]
          :status -> state_label(state(t))
          :inserted_at -> t.inserted_at
        end
      end)

    if direction == :asc, do: sorted, else: Enum.reverse(sorted)
  end

  ## Events — búsqueda / orden / archivo -------------------------------------

  @impl true
  def handle_event("search_topups", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> load_topups()}
  end

  def handle_event("sort_topups", %{"field" => field}, socket) do
    with true <- field in Enum.map(@sort_columns, &to_string/1) do
      field = String.to_existing_atom(field)

      direction =
        if socket.assigns.sort_field == field and socket.assigns.sort_direction == :desc,
          do: :asc,
          else: :desc

      {:noreply,
       socket
       |> assign(:sort_field, field)
       |> assign(:sort_direction, direction)
       |> load_topups()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_archived, not socket.assigns.show_archived)
     |> load_topups()}
  end

  ## Events — CRUD ----------------------------------------------------------

  def handle_event("new_topup", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_topup_id, nil)
     |> assign(:selected_owner, nil)
     |> assign(:owner_query, "")
     # Se ofrecen los primeros sujetos sin escribir nada: el selector tiene que
     # ser usable de un clic.
     |> assign(:owner_results, search_users(""))
     |> assign(
       :form,
       to_form(Topups.change_topup(%Topup{}), as: :topup)
     )}
  end

  def handle_event("edit_topup", %{"id" => id}, socket) do
    topup = Topups.get_topup!(id)

    {:noreply,
     socket
     |> assign(:editing_topup_id, topup.id)
     |> assign(:selected_owner, nil)
     |> assign(:owner_query, "")
     |> assign(:owner_results, [])
     |> assign(:form, to_form(Topups.change_topup(topup), as: :topup))}
  end

  def handle_event("cancel_topup", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:editing_topup_id, nil)}
  end

  # El formulario ofrece un solo dueño: usuario o servicio.
  def handle_event("owner_kind", %{"kind" => kind}, socket) when kind in ["user", "service"] do
    results = if kind == "user", do: search_users(""), else: search_services("")

    {:noreply,
     socket
     |> assign(:owner_kind, kind)
     |> assign(:owner_query, "")
     |> assign(:owner_results, results)
     |> assign(:selected_owner, nil)}
  end

  def handle_event("search_owner", %{"q" => query}, socket) do
    results =
      case socket.assigns.owner_kind do
        "user" -> search_users(query)
        "service" -> search_services(query)
      end

    {:noreply, socket |> assign(:owner_query, query) |> assign(:owner_results, results)}
  end

  def handle_event("select_owner", %{"id" => id}, socket) do
    owner =
      case socket.assigns.owner_kind do
        "user" -> Accounts.get_user(id)
        "service" -> Accounts.get_service(id)
      end

    {:noreply,
     socket
     |> assign(:selected_owner, owner && {socket.assigns.owner_kind, owner})
     |> assign(:owner_results, [])
     |> assign(:owner_query, owner_name(owner))}
  end

  def handle_event("save_topup", %{"topup" => params}, socket) do
    attrs = topup_attrs(params, socket)

    result =
      case socket.assigns.editing_topup_id do
        nil -> Topups.create(attrs)
        id -> Topups.edit_topup(Topups.get_topup!(id), attrs)
      end

    case result do
      {:ok, topup} ->
        audit(
          socket,
          if(socket.assigns.editing_topup_id, do: "topup.update", else: "topup.create"),
          "topup",
          topup.id,
          %{"amount_usd" => to_string(topup.amount_usd), "label" => topup.label}
        )

        {:noreply,
         socket
         |> assign(:form, nil)
         |> assign(:editing_topup_id, nil)
         |> load_topups()
         |> put_flash(:info, gettext("Top-up saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :topup))}
    end
  end

  # Desactivar/reactivar: dejar de otorgar el saldo restante (lo ya consumido
  # sigue visible en la columna Consumo) hasta reactivar.
  def handle_event("toggle_topup_status", %{"id" => id}, socket) do
    topup = Topups.get_topup!(id)

    {result, message} =
      case topup.status do
        "active" ->
          {Topups.revoke(topup),
           gettext("Top-up deactivated — the remaining balance stops being granted.")}

        _ ->
          {Topups.reactivate(topup), gettext("Top-up reactivated.")}
      end

    case result do
      {:ok, _} ->
        audit(socket, "topup.toggle_status", "topup", topup.id, %{
          "status" => if(topup.status == "active", do: "inactive", else: "active")
        })

        {:noreply, socket |> load_topups() |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change the status."))}
    end
  end

  def handle_event("revoke_topup", %{"id" => id}, socket) do
    topup = Topups.get_topup!(id)

    case Topups.revoke(topup) do
      {:ok, _} ->
        audit(socket, "topup.revoke", "topup", topup.id, %{"label" => topup.label})

        {:noreply, socket |> load_topups() |> put_flash(:info, gettext("Top-up revoked."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not revoke."))}
    end
  end

  ## Helpers ----------------------------------------------------------------

  # El dueño sale del selector (usuario/servicio) o del top-up que se edita.
  defp topup_attrs(params, socket) do
    {user_id, service_id} =
      case socket.assigns.selected_owner do
        {"user", %{id: id}} ->
          {id, nil}

        {"service", %{id: id}} ->
          {nil, id}

        nil ->
          editing_owner(socket.assigns.editing_topup_id)
      end

    %{
      "user_id" => user_id,
      "service_id" => service_id,
      "amount_usd" => Map.get(params, "amount_usd"),
      "label" => Map.get(params, "label"),
      "note" => Map.get(params, "note"),
      "expires_in_days" => blank_to_nil(Map.get(params, "expires_in_days"))
    }
  end

  defp editing_owner(nil), do: {nil, nil}

  defp editing_owner(id) do
    case Topups.get_topup!(id) do
      %{user_id: uid, service_id: sid} -> {uid, sid}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp search_users(query) do
    q = String.downcase(query)

    Accounts.list_users()
    |> Enum.filter(fn u -> q == "" or String.contains?(String.downcase(u.email), q) end)
    |> Enum.take(8)
  end

  defp search_services(query) do
    q = String.downcase(query)

    Accounts.list_services()
    |> Enum.filter(fn s -> q == "" or String.contains?(String.downcase(s.name), q) end)
    |> Enum.take(8)
  end

  # Nombre y línea secundaria de un candidato (usuario o servicio), sin asumir
  # la forma del struct: el selector ofrece ambos.
  defp subject_primary(%{name: name}) when is_binary(name) and name != "", do: name
  defp subject_primary(%{email: email}) when is_binary(email), do: email
  defp subject_primary(%{id: id}), do: String.slice(id, 0, 8)

  defp subject_secondary(%{email: email, name: name}) when is_binary(email) and is_binary(name),
    do: email

  defp subject_secondary(_), do: nil

  # Etiqueta del dueño elegido en el form: usuario (email) o servicio (nombre).
  defp owner_badge({"user", %{email: email}}), do: gettext("User:") <> " " <> email
  defp owner_badge({"service", %{name: name}}), do: gettext("Service:") <> " " <> name
  defp owner_badge(_), do: "—"

  defp owner_name(%{email: email}), do: email
  defp owner_name(%{name: name}), do: name
  defp owner_name(_), do: ""
end
