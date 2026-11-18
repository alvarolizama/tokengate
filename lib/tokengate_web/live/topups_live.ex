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
  alias Tokengate.Logs.RequestLog
  alias Tokengate.Repo

  import Ecto.Query

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
        # One-shot token for the top-up form: the double-submit guard. Minted
        # when the modal opens and consumed by the first successful save.
        |> assign(:form_token, nil)
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
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
      end
    end)
  end

  ## Data loading -----------------------------------------------------------

  defp load_topups(socket) do
    topups = Topups.list_all()
    consumed = consumed_by_topup_id(topups)
    archived = Enum.filter(topups, &archived?(&1, consumed))
    visible = visible_topups(topups, consumed, socket)

    socket
    |> assign(:consumed, consumed)
    |> assign(:archived_count, length(archived))
    |> assign(:all_topups, topups)
    |> assign(:topups_empty?, visible == [])
    |> stream(:topups, visible, reset: true)
  end

  defp visible_topups(topups, consumed, socket) do
    assigns = socket.assigns

    topups
    |> Enum.filter(fn t -> assigns.show_archived || not archived?(t, consumed) end)
    |> filter_by_query(assigns.search_query)
    |> sort(assigns.sort_field, assigns.sort_direction, consumed)
  end

  defp filter_by_query(topups, ""), do: topups

  defp filter_by_query(topups, query) do
    q = String.downcase(query)

    Enum.filter(topups, fn t ->
      String.contains?(String.downcase(owner_label(t)), q) or
        String.contains?(String.downcase(t.label || ""), q)
    end)
  end

  defp sort(topups, field, direction, consumed) do
    sorted =
      Enum.sort_by(topups, fn t ->
        case field do
          :target -> owner_label(t)
          :amount -> Decimal.to_float(t.amount_usd)
          :expires_at -> t.expires_at || ~U[9999-12-31 00:00:00Z]
          :status -> state_label(row_state(t, consumed))
          :inserted_at -> t.inserted_at
        end
      end)

    if direction == :asc, do: sorted, else: Enum.reverse(sorted)
  end

  ## Consumo / estado de una fila -------------------------------------------

  # La tabla pinta el consumo de CADA fila y el estado (agotado/archivado)
  # depende de él. Resolverlo con `Topups.consumed_usd/1` —o con `state/1` y
  # `archived?/1` de `TopupHelpers`, que lo llaman por dentro— costaba una
  # query por fila, repetida en cada celda y en cada pasada del filtro: un
  # N+1 sobre `request_logs`. Aquí el consumo se resuelve UNA vez por carga
  # (una query agrupada) y viaja en el assign `:consumed`.
  @consumption_grace_hours 24

  defp consumed_by_topup_id([]), do: %{}

  defp consumed_by_topup_id(topups) do
    ids = Enum.map(topups, & &1.id)
    floor = consumption_floor(topups)

    RequestLog
    |> where([rl], rl.credit_topup_id in ^ids)
    |> where([rl], rl.inserted_at >= ^floor)
    |> group_by([rl], rl.credit_topup_id)
    |> select([rl], {rl.credit_topup_id, fragment("COALESCE(SUM(?), 0)", rl.provider_cost_usd)})
    |> Repo.all()
    |> Map.new(fn {id, cost} -> {id, Decimal.new(to_string(cost))} end)
  end

  # Misma cota que `Topups.consumed_usd/1` (creación menos la hora de gracia),
  # aplicada una vez al lote: el top-up más antiguo es el instante más temprano
  # en que cualquiera pudo ser debitado.
  defp consumption_floor(topups) do
    topups
    |> Enum.map(& &1.inserted_at)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond))
    |> DateTime.add(-@consumption_grace_hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

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
         %Topup{} = topup <- Topups.get_topup(id) do
      {:noreply,
       socket
       |> assign(:editing_topup_id, topup.id)
       |> assign(:form_token, Ecto.UUID.generate())
       |> assign(:selected_owner, nil)
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

  # The owner search input carries its own `phx-change`, so LiveView ships the
  # typed value under the `value` key — NOT under the input's `name`, which only
  # travels as `_target`. The old clause expected `%{"q" => _}` and never
  # matched a real payload, so the LiveView died on the first keystroke. The
  # catch-all closes the family: an unexpected payload is ignored.
  def handle_event("search_owner", %{"value" => query}, socket) when is_binary(query) do
    results =
      case socket.assigns.owner_kind do
        "user" -> search_users(query)
        "service" -> search_services(query)
        _ -> []
      end

    {:noreply, socket |> assign(:owner_query, query) |> assign(:owner_results, results)}
  end

  def handle_event("search_owner", _params, socket), do: {:noreply, socket}

  def handle_event("select_owner", %{"id" => id}, socket) do
    case owner_for(socket.assigns.owner_kind, id) do
      nil ->
        {:noreply, socket}

      owner ->
        {:noreply,
         socket
         |> assign(:selected_owner, {socket.assigns.owner_kind, owner})
         |> assign(:owner_results, [])
         |> assign(:owner_query, owner_name(owner))}
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
