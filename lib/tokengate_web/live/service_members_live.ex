defmodule TokengateWeb.ServiceMembersLive do
  @moduledoc """
  Admin-only supervisor management for a service (`/access/services/:id/members`).

  Supervisors are regular users granted read-only access to the service under
  `/services/supervised` via `service_supervisors`. Adding or removing a
  supervisor broadcasts immediately on `Accounts.supervised_services_topic/1`.
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents
  alias Tokengate.Accounts
  alias Tokengate.Accounts.{Service, User}

  @per_page 30
  @sort_columns ~w(email name inserted_at)a

  @impl true
  def mount(%{"id" => service_id}, _session, socket) do
    user = socket.assigns[:current_user]

    if is_nil(user) or user.global_role != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
       |> redirect(to: "/dashboard")}
    else
      case fetch_service(service_id) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, gettext("Service not found."))
           |> redirect(to: "/access/services")}

        %Service{} = service ->
          socket =
            socket
            |> assign(
              :page_title,
              gettext("Members of %{name}", name: service.name) <> " · Tokengate"
            )
            |> assign(:is_admin, true)
            |> require_admin_hook()
            |> assign(:service, service)
            |> assign(:search_query, "")
            |> assign(:sort_field, :email)
            |> assign(:sort_direction, :asc)
            |> assign(:page, 1)
            |> assign(:per_page, @per_page)
            |> assign(:total_count, 0)
            |> assign(:total_pages, 1)
            |> assign(:show_add_modal?, false)
            |> assign(:user_search_form, to_form(%{"query" => ""}, as: :search))
            |> assign(:user_search_query, "")
            |> assign(:user_search_results, [])
            |> stream_configure(:members, dom_id: &"service-member-#{&1.id}")
            |> load_members()

          {:ok, socket}
      end
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

  ## Data loading ---------------------------------------------------------

  defp load_members(socket) do
    page =
      Accounts.list_service_supervisors_page(
        socket.assigns.service.id,
        search: socket.assigns[:search_query] || "",
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        sort_field: socket.assigns.sort_field,
        sort_direction: socket.assigns.sort_direction
      )

    socket
    |> assign(:page, page.page)
    |> assign(:total_count, page.total)
    |> assign(:total_pages, page.total_pages)
    |> assign(:members_empty?, page.total == 0)
    |> stream(:members, page.entries, reset: true)
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("search_members", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 1)
     |> load_members()}
  end

  def handle_event("go_to_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, parse_page(page))
     |> load_members()}
  end

  def handle_event("sort_members", %{"field" => field}, socket) do
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
       |> assign(:page, 1)
       |> load_members()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("new_member", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal?, true)
     |> assign(:user_search_form, to_form(%{"query" => ""}, as: :search))
     |> assign(:user_search_query, "")
     |> assign(:user_search_results, [])}
  end

  def handle_event("cancel_add_member", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal?, false)
     |> assign(:user_search_form, to_form(%{"query" => ""}, as: :search))
     |> assign(:user_search_query, "")
     |> assign(:user_search_results, [])}
  end

  def handle_event("search_users", %{"search" => %{"query" => query}}, socket) do
    do_search_users(query, socket)
  end

  def handle_event("search_users", %{"query" => query}, socket) do
    do_search_users(query, socket)
  end

  def handle_event("search_users", %{"value" => query}, socket) do
    do_search_users(query, socket)
  end

  def handle_event("add_member", %{"user-id" => user_id}, socket) do
    do_add_member(user_id, socket)
  end

  def handle_event("add_member", %{"user_id" => user_id}, socket) do
    do_add_member(user_id, socket)
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    do_remove_member(user_id, socket)
  end

  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    do_remove_member(user_id, socket)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Private helpers ------------------------------------------------------

  defp do_search_users(query, socket) when is_binary(query) do
    trimmed = String.trim(query)

    results =
      if trimmed == "" do
        []
      else
        supervisor_ids = Accounts.service_supervisor_ids(socket.assigns.service.id)

        trimmed
        |> Accounts.search_users_for_picker(25)
        |> Enum.reject(&(&1.id in supervisor_ids))
      end

    {:noreply,
     socket
     |> assign(:user_search_form, to_form(%{"query" => query}, as: :search))
     |> assign(:user_search_query, query)
     |> assign(:user_search_results, results)}
  end

  defp do_search_users(_query, socket), do: {:noreply, socket}

  defp do_add_member(user_id, socket) do
    service = socket.assigns.service

    with {:ok, user_uuid} <- cast_id(user_id),
         %User{} <- Accounts.get_user(user_uuid),
         {:ok, _supervisor} <- Accounts.add_service_supervisor(service.id, user_uuid) do
      audit(socket, "service_supervisor.add", "service", service.id, %{"user_id" => user_uuid})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Supervisor added."))
       |> assign(:show_add_modal?, false)
       |> assign(:user_search_form, to_form(%{"query" => ""}, as: :search))
       |> assign(:user_search_query, "")
       |> assign(:user_search_results, [])
       |> load_members()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not add the supervisor."))}
    end
  end

  defp do_remove_member(user_id, socket) do
    service = socket.assigns.service

    with {:ok, user_uuid} <- cast_id(user_id),
         {:ok, :removed} <- Accounts.remove_service_supervisor(service.id, user_uuid) do
      audit(socket, "service_supervisor.remove", "service", service.id, %{"user_id" => user_uuid})

      {:noreply,
       socket
       |> put_flash(:info, gettext("Supervisor removed."))
       |> load_members()}
    else
      {:ok, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Supervisor not found."))
         |> load_members()}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the supervisor."))}
    end
  end

  defp fetch_service(service_id) do
    with {:ok, uuid} <- cast_id(service_id) do
      Accounts.get_service(uuid)
    else
      _ -> nil
    end
  end

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_), do: :error

  defp to_sort_field(field) when is_binary(field) do
    {:ok, String.to_existing_atom(field)}
  rescue
    ArgumentError -> :error
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {i, ""} when i > 0 -> i
      _ -> 1
    end
  end

  defp parse_page(page) when is_integer(page) and page > 0, do: page
  defp parse_page(_), do: 1

  defp toggle_sort_direction(:asc), do: :desc
  defp toggle_sort_direction(:desc), do: :asc

  defp default_direction_for(:inserted_at), do: :desc
  defp default_direction_for(_), do: :asc

  defp initials(%User{name: name}) when is_binary(name) and byte_size(name) > 0 do
    name
    |> String.trim()
    |> String.split(~r/\s+/)
    |> Enum.take(2)
    |> Enum.map(&String.slice(&1, 0, 1))
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(%User{email: email}) when is_binary(email) do
    case String.split(email, "@") do
      [local | _] -> local |> String.slice(0, 2) |> String.upcase()
      _ -> "—"
    end
  end

  defp initials(_), do: "—"

  defp role_badge("admin"), do: "badge-primary"
  defp role_badge(_), do: "badge-ghost"

  ## Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard
      flash={@flash}
      current_scope={@current_user}
      impersonator={@impersonator}
      current_path={@current_path}
    >
      <div class="space-y-6">
        <.header>
          {gettext("Members of %{name}", name: @service.name)}
          <:subtitle>{gettext("Manage read-only supervisors for this service")}</:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-3">
              <.admin_search
                event="search_members"
                value={@search_query}
                placeholder={gettext("Search by email or name…")}
                input_id="service-member-search"
              />
              <.button phx-click="new_member" id="new-member-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add member")}
              </.button>
              <.link
                navigate={~p"/access/services"}
                class="btn btn-ghost btn-sm"
                id="back-to-services"
              >
                <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back")}
              </.link>
            </div>
          </:actions>
        </.header>

        <%!-- Add member modal --%>
        <.modal
          :if={@show_add_modal?}
          id="add-service-member-modal"
          title={gettext("Add member")}
          on_close="cancel_add_member"
          max_w="max-w-lg"
        >
          <.form
            for={@user_search_form}
            id="add-service-member-form"
            phx-change="search_users"
            phx-submit="search_users"
          >
            <.input
              field={@user_search_form[:query]}
              type="text"
              label={gettext("Search user")}
              placeholder={gettext("Search by email or name…")}
              phx-debounce="250"
              autocomplete="off"
              id="add-service-member-search"
            />
          </.form>

          <div
            :if={@user_search_query != "" and @user_search_results == []}
            class="text-xs text-base-content/50 mt-2"
            id="user-search-empty"
          >
            {gettext("No matches.")}
          </div>

          <div
            :if={@user_search_results != []}
            class="mt-2 max-h-60 overflow-y-auto border border-base-300 rounded-lg divide-y divide-base-200"
            id="user-search-results"
          >
            <button
              :for={user <- @user_search_results}
              type="button"
              phx-click="add_member"
              phx-value-user-id={user.id}
              class="w-full text-left px-3 py-2 text-sm hover:bg-base-200 transition-colors flex items-center justify-between gap-3"
              id={"add-user-#{user.id}"}
            >
              <div class="min-w-0">
                <p class="font-medium truncate">{user.name || user.email}</p>
                <p class="text-xs text-base-content/60 truncate">{user.email}</p>
              </div>
              <span class="badge badge-sm badge-ghost shrink-0">{user.global_role}</span>
            </button>
          </div>

          <:footer>
            <button
              type="button"
              phx-click="cancel_add_member"
              class="btn btn-ghost btn-sm"
              id="cancel-add-service-member"
            >
              {gettext("Cancel")}
            </button>
          </:footer>
        </.modal>

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="service-members-rows"
            rows={@streams.members}
            row_item={fn {_id, member} -> member end}
            row_class="align-top"
            sort_field={@sort_field}
            sort_direction={@sort_direction}
            sort_event="sort_members"
            empty?={@members_empty?}
          >
            <:col :let={member} label={gettext("Member")} field={:email}>
              <.admin_identity
                initials={initials(member.user)}
                title={member.user.name || member.user.email}
                subtitle={member.user.email}
                truncate
              />
            </:col>
            <:col :let={member} label={gettext("Role")}>
              <span class={["badge badge-sm", role_badge(member.user.global_role)]}>
                {member.user.global_role}
              </span>
            </:col>
            <:col :let={member} label={gettext("Assigned")} field={:inserted_at}>
              <span class="text-xs text-base-content/50">
                {format_date(member.inserted_at, @timezone)}
              </span>
            </:col>
            <:action :let={member}>
              <button
                type="button"
                phx-click="remove_member"
                phx-value-user-id={member.user_id}
                class="btn btn-xs btn-ghost text-error"
                id={"remove-#{member.user_id}"}
                title={gettext("Remove")}
                aria-label={gettext("Remove")}
                data-confirm={
                  gettext(
                    "Remove this supervisor? They will immediately lose read-only access to this service."
                  )
                }
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
              </button>
            </:action>
            <:empty>
              <div id="service-members-empty">
                <.icon name="hero-users" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p>{gettext("No supervisors assigned.")}</p>
              </div>
            </:empty>
          </.table>
          <.admin_pagination
            id="service-members-pagination"
            page={@page}
            per_page={@per_page}
            total={@total_count}
            total_pages={@total_pages}
          />
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
