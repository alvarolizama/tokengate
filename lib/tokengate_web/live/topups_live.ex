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

  import TokengateWeb.AdminComponents
  import TokengateWeb.KpiHelpers, only: [kpi_card: 1]
  import TokengateWeb.TopupHelpers

  @per_page 30
  @sort_columns ~w(target amount remaining expires_at status inserted_at)a
  @expiring_window_days 7

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
        # One-shot token for the top-up form: the double-submit guard. Minted
        # when the modal opens and consumed by the first successful save.
        |> assign(:form_token, nil)
        |> assign(:owner_kind, "user")
        |> assign(:owner_query, "")
        |> assign(:owner_results, [])
        |> assign(:selected_owner, nil)
        |> assign(:search_query, "")
        |> assign(:owner_filter, :all)
        |> assign(:status_filter, :all)
        |> assign(:sort_field, :inserted_at)
        |> assign(:sort_direction, :desc)
        |> assign(:show_archived, false)
        |> assign(:archived_count, 0)
        |> assign(:page, 1)
        |> assign(:per_page, @per_page)
        |> assign(:total_count, 0)
        |> assign(:total_pages, 1)
        |> load_topups()

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"owner_kind" => kind, "owner_id" => id}, _uri, socket)
      when kind in ["user", "service"] do
    case owner_for(kind, id) do
      nil ->
        {:noreply, socket}

      owner ->
        {:noreply,
         socket
         |> assign(:editing_topup_id, nil)
         |> assign(:owner_kind, kind)
         |> assign(:selected_owner, {kind, owner})
         |> assign(:owner_query, "")
         |> assign(:owner_results, [])
         |> assign(:form_token, Ecto.UUID.generate())
         |> assign(:form, to_form(Topups.change_topup(%Topup{}), as: :topup))}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
      end
    end)
  end

  ## Data loading -----------------------------------------------------------

  defp load_topups(socket) do
    topups = Topups.list_all()
    consumed = Topups.consumed_by_topup_ids(topups)
    archived = Enum.filter(topups, &archived?(&1, consumed))
    kpis = compute_kpis(topups, consumed)

    socket
    |> assign(:consumed, consumed)
    |> assign(:archived_count, length(archived))
    |> assign(:kpis, kpis)
    |> assign(:all_topups, topups)
    |> stream_topups()
  end

  defp compute_kpis(topups, consumed) do
    Enum.reduce(
      topups,
      %{
        active_count: 0,
        active_users: 0,
        active_services: 0,
        active_granted: Decimal.new(0),
        active_consumed: Decimal.new(0),
        active_remaining: Decimal.new(0),
        expiring_count: 0,
        expiring_remaining: Decimal.new(0),
        revoked_count: 0,
        archived_count: 0
      },
      fn topup, acc ->
        state = row_state(topup, consumed)
        c = row_consumed(topup, consumed)
        rem = row_remaining(topup, consumed)

        case state do
          :active ->
            acc = %{
              acc
              | active_count: acc.active_count + 1,
                active_users: acc.active_users + if(topup.user_id, do: 1, else: 0),
                active_services: acc.active_services + if(topup.service_id, do: 1, else: 0),
                active_granted: Decimal.add(acc.active_granted, topup.amount_usd),
                active_consumed: Decimal.add(acc.active_consumed, c),
                active_remaining: Decimal.add(acc.active_remaining, rem)
            }

            if expiring_soon?(topup, consumed) do
              %{
                acc
                | expiring_count: acc.expiring_count + 1,
                  expiring_remaining: Decimal.add(acc.expiring_remaining, rem)
              }
            else
              acc
            end

          :revoked ->
            %{acc | revoked_count: acc.revoked_count + 1}

          _archived ->
            %{acc | archived_count: acc.archived_count + 1}
        end
      end
    )
  end

  # Filters, sorts and paginates already-loaded top-ups in memory (zero DB queries).
  defp stream_topups(socket) do
    visible = visible_topups(socket.assigns.all_topups, socket.assigns.consumed, socket)
    total = length(visible)
    per_page = socket.assigns.per_page
    total_pages = max(1, div(total + per_page - 1, per_page))
    page = socket.assigns.page |> max(1) |> min(total_pages)
    entries = Enum.slice(visible, (page - 1) * per_page, per_page)

    socket
    |> assign(:page, page)
    |> assign(:total_count, total)
    |> assign(:total_pages, total_pages)
    |> assign(:topups_empty?, total == 0)
    |> stream(:topups, entries, reset: true)
  end

  defp visible_topups(topups, consumed, socket) do
    assigns = socket.assigns

    topups
    |> Enum.filter(fn t -> assigns.show_archived || not archived?(t, consumed) end)
    |> filter_by_owner_kind(assigns.owner_filter)
    |> filter_by_status(assigns.status_filter, consumed)
    |> filter_by_query(assigns.search_query)
    |> sort(assigns.sort_field, assigns.sort_direction, consumed)
  end

  defp filter_by_owner_kind(topups, :all), do: topups
  defp filter_by_owner_kind(topups, :user), do: Enum.filter(topups, & &1.user_id)
  defp filter_by_owner_kind(topups, :service), do: Enum.filter(topups, & &1.service_id)

  defp filter_by_status(topups, :all, _consumed), do: topups

  defp filter_by_status(topups, :active, consumed),
    do: Enum.filter(topups, &(row_state(&1, consumed) == :active))

  defp filter_by_status(topups, :expiring, consumed),
    do: Enum.filter(topups, &expiring_soon?(&1, consumed))

  defp filter_by_status(topups, :revoked, consumed),
    do: Enum.filter(topups, &(row_state(&1, consumed) == :revoked))

  defp filter_by_query(topups, ""), do: topups

  defp filter_by_query(topups, query) do
    q = String.downcase(String.trim(query))

    if q == "" do
      topups
    else
      Enum.filter(topups, fn t ->
        user_name = if t.user && t.user.name, do: t.user.name, else: ""

        String.contains?(String.downcase(owner_label(t)), q) or
          String.contains?(String.downcase(user_name), q) or
          String.contains?(String.downcase(t.label || ""), q) or
          String.contains?(String.downcase(t.note || ""), q)
      end)
    end
  end

  defp sort(topups, field, direction, consumed) do
    sorted =
      Enum.sort_by(topups, fn t ->
        case field do
          :target -> String.downcase(owner_label(t))
          :amount -> Decimal.to_float(t.amount_usd)
          :remaining -> Decimal.to_float(row_remaining(t, consumed))
          :expires_at -> t.expires_at || ~U[9999-12-31 00:00:00Z]
          :status -> state_label(row_state(t, consumed))
          :inserted_at -> t.inserted_at
        end
      end)

    if direction == :asc, do: sorted, else: Enum.reverse(sorted)
  end

  ## Consumo / estado de una fila -------------------------------------------

  defp row_consumed(topup, consumed), do: Map.get(consumed, topup.id, Decimal.new(0))

  defp row_remaining(topup, consumed) do
    remaining = Decimal.sub(topup.amount_usd, row_consumed(topup, consumed))

    if Decimal.compare(remaining, 0) == :lt, do: Decimal.new(0), else: remaining
  end

  defp row_state(topup, consumed) do
    cond do
      topup.status == "revoked" -> :revoked
      expired?(topup) -> :expired
      Decimal.compare(row_remaining(topup, consumed), 0) != :gt -> :exhausted
      true -> :active
    end
  end

  defp archived?(topup, consumed), do: row_state(topup, consumed) in [:expired, :exhausted]

  defp expiring_soon?(%{expires_at: nil}, _consumed), do: false

  defp expiring_soon?(%{expires_at: %DateTime{} = dt} = topup, consumed) do
    row_state(topup, consumed) == :active and
      DateTime.compare(dt, DateTime.add(DateTime.utc_now(), @expiring_window_days, :day)) != :gt
  end

  defp row_pct(topup, consumed) do
    amount = topup.amount_usd

    if Decimal.compare(amount, 0) != :gt do
      0.0
    else
      row_consumed(topup, consumed)
      |> Decimal.div(amount)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_float()
      |> min(100.0)
    end
  end

  ## Events — búsqueda / filtros / orden / archivo / paginado -----------------

  @impl true
  def handle_event("search_topups", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> assign(:page, 1) |> stream_topups()}
  end

  def handle_event("filter_owner_kind", %{"kind" => kind}, socket)
      when kind in ["all", "user", "service"] do
    {:noreply,
     socket
     |> assign(:owner_filter, String.to_existing_atom(kind))
     |> assign(:page, 1)
     |> stream_topups()}
  end

  def handle_event("filter_status", %{"status" => status}, socket)
      when status in ["all", "active", "expiring", "revoked"] do
    {:noreply,
     socket
     |> assign(:status_filter, String.to_existing_atom(status))
     |> assign(:page, 1)
     |> stream_topups()}
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, parse_page(page)) |> stream_topups()}
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
       |> assign(:page, 1)
       |> stream_topups()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_archived, not socket.assigns.show_archived)
     |> assign(:page, 1)
     |> stream_topups()}
  end

  ## Events — CRUD ----------------------------------------------------------

  def handle_event("new_topup", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_topup_id, nil)
     |> assign(:owner_kind, "user")
     |> assign(:selected_owner, nil)
     |> assign(:owner_query, "")
     |> assign(:form_token, Ecto.UUID.generate())
     # Se ofrecen los primeros sujetos sin escribir nada: el selector tiene que
     # ser usable de un clic.
     |> assign(:owner_results, search_users(""))
     |> assign(
       :form,
       to_form(Topups.change_topup(%Topup{}), as: :topup)
     )}
  end

  def handle_event("edit_topup", %{"id" => id}, socket) do
    with {:ok, id} <- cast_id(id),
         %Topup{} = topup <- Topups.get_topup_with_owner(id) do
      {owner_kind, selected_owner} =
        cond do
          topup.user -> {"user", {"user", topup.user}}
          topup.service -> {"service", {"service", topup.service}}
          true -> {"user", nil}
        end

      {:noreply,
       socket
       |> assign(:editing_topup_id, topup.id)
       |> assign(:form_token, Ecto.UUID.generate())
       |> assign(:owner_kind, owner_kind)
       |> assign(:selected_owner, selected_owner)
       |> assign(:owner_query, "")
       |> assign(:owner_results, [])
       |> assign(:form, to_form(Topups.change_topup(topup), as: :topup))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Top-up not found."))}
    end
  end

  def handle_event("edit_topup", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_topup", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_topup_id, nil)
     # Dropping the token also drops a submit that was already in flight.
     |> assign(:form_token, nil)}
  end

  # El formulario ofrece un solo dueño: usuario o servicio (bloqueado al editar).
  def handle_event("owner_kind", %{"kind" => kind}, socket) when kind in ["user", "service"] do
    if socket.assigns.editing_topup_id do
      {:noreply, socket}
    else
      results = if kind == "user", do: search_users(""), else: search_services("")

      {:noreply,
       socket
       |> assign(:owner_kind, kind)
       |> assign(:owner_query, "")
       |> assign(:owner_results, results)
       |> assign(:selected_owner, nil)}
    end
  end

  def handle_event("clear_selected_owner", _params, socket) do
    if socket.assigns.editing_topup_id do
      {:noreply, socket}
    else
      results =
        if socket.assigns.owner_kind == "user", do: search_users(""), else: search_services("")

      {:noreply,
       socket
       |> assign(:selected_owner, nil)
       |> assign(:owner_query, "")
       |> assign(:owner_results, results)}
    end
  end

  # The owner search input carries its own `phx-change`, so LiveView ships the
  # typed value under the `value` key — NOT under the input's `name`, which only
  # travels as `_target`. The old clause expected `%{"q" => _}` and never
  # matched a real payload, so the LiveView died on the first keystroke. The
  # catch-all closes the family: an unexpected payload is ignored.
  def handle_event("search_owner", %{"value" => query}, socket) when is_binary(query) do
    if socket.assigns.editing_topup_id do
      {:noreply, socket}
    else
      results =
        case socket.assigns.owner_kind do
          "user" -> search_users(query)
          "service" -> search_services(query)
          _ -> []
        end

      {:noreply, socket |> assign(:owner_query, query) |> assign(:owner_results, results)}
    end
  end

  def handle_event("search_owner", _params, socket), do: {:noreply, socket}

  def handle_event("select_owner", %{"id" => id}, socket) do
    if socket.assigns.editing_topup_id do
      {:noreply, socket}
    else
      case owner_for(socket.assigns.owner_kind, id) do
        nil ->
          {:noreply, socket}

        owner ->
          {:noreply,
           socket
           |> assign(:selected_owner, {socket.assigns.owner_kind, owner})
           |> assign(:owner_results, [])
           |> assign(:owner_query, "")}
      end
    end
  end

  def handle_event("select_owner", _params, socket), do: {:noreply, socket}

  # A double click on Guardar (or a submit queued right behind the first one)
  # used to insert TWO top-ups. The modal carries a one-shot token: the first
  # save consumes it, so every later submit of the same form is a no-op.
  def handle_event("save_topup", %{"topup" => params} = payload, socket) do
    if valid_form_token?(socket, payload["idempotency_key"]) do
      save_topup(socket, params)
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_topup", _params, socket), do: {:noreply, socket}

  # Deactivate/reactivate: stop granting the remaining balance (what was already
  # consumed stays visible in the Consumption column) until reactivated.
  def handle_event("toggle_topup_status", %{"id" => id}, socket) do
    with {:ok, id} <- cast_id(id),
         %Topup{} = topup <- Topups.get_topup(id) do
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
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Top-up not found."))}
    end
  end

  def handle_event("toggle_topup_status", _params, socket), do: {:noreply, socket}

  def handle_event("revoke_topup", %{"id" => id}, socket) do
    with {:ok, id} <- cast_id(id),
         %Topup{} = topup <- Topups.get_topup(id) do
      case Topups.revoke(topup) do
        {:ok, _} ->
          audit(socket, "topup.revoke", "topup", topup.id, %{"label" => topup.label})

          {:noreply, socket |> load_topups() |> put_flash(:info, gettext("Top-up revoked."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not revoke."))}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Top-up not found."))}
    end
  end

  def handle_event("revoke_topup", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Helpers ----------------------------------------------------------------

  # Client ids arrive as strings: cast before ANY DB call so a malformed id is
  # a flash / no-op instead of an `Ecto.Query.CastError` that kills the view.
  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_id), do: :error

  defp owner_for(kind, id) do
    case cast_id(id) do
      {:ok, uuid} ->
        case kind do
          "user" -> Accounts.get_user(uuid)
          "service" -> Accounts.get_service(uuid)
          _ -> nil
        end

      :error ->
        nil
    end
  end

  # The one-shot submit token. Both sides must be present: a socket without an
  # open form (nil) never accepts a payload, even a forged one.
  defp valid_form_token?(socket, token) do
    current = socket.assigns[:form_token]
    is_binary(token) and is_binary(current) and token == current
  end

  # Writes the top-up only once per form-open (token already validated). The
  # token is consumed on success and ROTATED on a changeset error, so the form
  # the user corrects can be submitted again.
  defp save_topup(socket, params) do
    attrs = topup_attrs(params, socket)

    result =
      case socket.assigns.editing_topup_id do
        nil ->
          Topups.create(attrs)

        id ->
          case Topups.get_topup(id) do
            nil -> {:error, :not_found}
            topup -> Topups.edit_topup(topup, attrs)
          end
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
         |> assign(:form_token, nil)
         |> load_topups()
         |> put_flash(:info, gettext("Top-up saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form_token, Ecto.UUID.generate())
         |> assign(:form, to_form(changeset, as: :topup))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:form_token, Ecto.UUID.generate())
         |> put_flash(:error, gettext("Top-up not found."))}
    end
  end

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
    case Topups.get_topup(id) do
      %{user_id: uid, service_id: sid} -> {uid, sid}
      nil -> {nil, nil}
    end
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {i, ""} when i > 0 -> i
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  defp search_users(query), do: Accounts.search_users_for_picker(query, 8)

  defp search_services(query), do: Accounts.search_services_for_picker(query, 8)

  defp owner_path(%{user_id: uid}) when is_binary(uid), do: ~p"/stats/users/#{uid}"
  defp owner_path(%{service_id: sid}) when is_binary(sid), do: ~p"/stats/services/#{sid}"
  defp owner_path(_), do: nil

  defp consumed_pct_label(%{active_granted: granted, active_consumed: consumed}) do
    if Decimal.compare(granted, 0) == :gt do
      pct =
        consumed
        |> Decimal.div(granted)
        |> Decimal.mult(100)
        |> Decimal.round(1)
        |> Decimal.to_string(:normal)

      "#{pct}%"
    else
      "0%"
    end
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
end
