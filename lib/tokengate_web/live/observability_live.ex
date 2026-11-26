defmodule TokengateWeb.ObservabilityLive do
  @moduledoc """
  Admin-only CRUD for observability destinations (OTLP webhooks).

  La observabilidad es de toda la instalación: los webhooks ya no cuelgan de un
  perfil de límites ni se filtran por él. Destinations live in a single compact table with
  search.
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents

  alias Tokengate.Observability
  alias Tokengate.Observability.Destination

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if user && user.global_role == "admin" do
      socket =
        socket
        |> assign(:page_title, gettext("Observability") <> " · Tokengate")
        |> assign(:is_admin, true)
        |> require_admin_hook()
        |> assign(:form, nil)
        |> assign(:editing_destination_id, nil)
        |> assign(:delete_target, nil)
        |> assign(:search, "")
        |> assign(:all_destinations, [])
        |> assign(:delivery_stats, %{})
        |> assign(:destinations_empty?, true)
        |> stream(:destinations, [], reset: true)

      socket = if connected?(socket), do: load_data(socket), else: socket

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to access this section."))
       |> redirect(to: "/dashboard")}
    end
  end

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a malicious client could fire events directly
  # over the WebSocket. Halt every event for non-admins.
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

  defp load_data(socket) do
    destinations = Observability.list_all_destinations()
    delivery_stats = Observability.destination_delivery_stats()

    socket
    |> assign(:all_destinations, destinations)
    |> assign(:delivery_stats, delivery_stats)
    |> stream_destinations()
  end

  # Pure in-memory filter + re-stream: zero queries on search events.
  defp stream_destinations(socket) do
    search = String.downcase(socket.assigns[:search] || "")

    filtered =
      Enum.filter(socket.assigns.all_destinations, fn d ->
        name = String.downcase(d.name || "")
        url = String.downcase(d.url || "")

        search == "" or String.contains?(name, search) or String.contains?(url, search)
      end)

    socket
    |> stream(:destinations, filtered, reset: true)
    |> assign(:destinations_empty?, filtered == [])
  end

  ## Events ---------------------------------------------------------------

  @impl true
  def handle_event("search", %{"q" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> stream_destinations()}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> stream_destinations()}
  end

  def handle_event("new_destination", _params, socket) do
    changeset = Observability.change_destination(%Destination{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :destination))
     |> assign(:editing_destination_id, :new)}
  end

  def handle_event("edit_destination", %{"id" => id}, socket) do
    case fetch_destination(id) do
      {:ok, destination} ->
        changeset = Observability.change_destination(destination)

        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: :destination))
         |> assign(:editing_destination_id, destination.id)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That webhook does not exist."))}
    end
  end

  def handle_event("validate_destination", %{"destination" => destination_params}, socket) do
    case destination_base(socket) do
      {:ok, base} ->
        changeset =
          case decode_headers(Map.get(destination_params, "headers")) do
            {:ok, headers} ->
              base
              |> Observability.change_destination(Map.put(destination_params, "headers", headers))
              |> Map.put(:action, :validate)

            {:error, :not_json} ->
              base
              |> Observability.change_destination(Map.drop(destination_params, ["headers"]))
              |> Ecto.Changeset.put_change(:headers, Map.get(destination_params, "headers"))
              |> Ecto.Changeset.add_error(:headers, "is invalid JSON")
              |> Map.put(:action, :validate)
          end

        {:noreply, assign(socket, :form, to_form(changeset, as: :destination))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_destination_id, nil)}
  end

  def handle_event("save_destination", %{"destination" => destination_params}, socket) do
    case destination_base(socket) do
      :cancelled ->
        # A submit already in flight lands right after Cancel cleared the id.
        {:noreply, socket}

      :missing ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That webhook does not exist."))
         |> assign(:form, nil)
         |> assign(:editing_destination_id, nil)}

      {:ok, base} ->
        save_destination(socket, base, destination_params)
    end
  end

  def handle_event("toggle_destination", %{"id" => id}, socket) do
    case fetch_destination(id) do
      {:ok, destination} ->
        case Observability.toggle_destination(destination) do
          {:ok, updated} ->
            audit(socket, "destination.toggle", "destination", updated.id, %{
              "name" => updated.name,
              "enabled" => updated.enabled
            })

            msg =
              if updated.enabled,
                do: gettext("Webhook enabled."),
                else: gettext("Webhook paused.")

            {:noreply,
             socket
             |> put_flash(:info, msg)
             |> load_data()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update the webhook."))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That webhook does not exist."))}
    end
  end

  def handle_event("test_destination", %{"id" => id}, socket) do
    case fetch_destination(id) do
      {:ok, destination} ->
        case Observability.test_destination(destination) do
          {:ok, %{status: status, latency_ms: ms}} ->
            audit(socket, "destination.test", "destination", destination.id, %{
              "name" => destination.name,
              "status" => status
            })

            {:noreply,
             put_flash(
               socket,
               :info,
               gettext("Test webhook delivered (HTTP %{status} in %{ms} ms).",
                 status: status,
                 ms: ms
               )
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Test webhook failed: %{reason}", reason: to_string(reason))
             )}
        end

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That webhook does not exist."))}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case fetch_destination(id) do
      {:ok, destination} ->
        {:noreply, assign(socket, :delete_target, destination)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That webhook does not exist."))}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  def handle_event("delete_destination", %{"id" => id}, socket) do
    socket = assign(socket, :delete_target, nil)

    case fetch_destination(id) do
      {:ok, destination} ->
        case Observability.delete_destination(destination) do
          {:ok, _} ->
            audit(socket, "destination.delete", "destination", destination.id, %{
              "name" => destination.name
            })

            {:noreply,
             socket
             |> put_flash(:info, gettext("Webhook deleted."))
             |> load_data()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete the webhook."))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, gettext("That webhook does not exist."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Private helpers -------------------------------------------------------

  # The headers textarea is edited as JSON text but stored as a :map. Invalid
  # JSON used to be smuggled in as `%{"_raw" => text}` and saved with a
  # "Webhook saved." flash; it is rejected now.
  defp save_destination(socket, base, destination_params) do
    case decode_headers(Map.get(destination_params, "headers")) do
      {:ok, headers} ->
        attrs = Map.put(destination_params, "headers", headers)

        result =
          if socket.assigns.editing_destination_id == :new do
            Observability.create_destination(attrs)
          else
            Observability.update_destination(base, attrs)
          end

        case result do
          {:ok, destination} ->
            audit(
              socket,
              if(socket.assigns.editing_destination_id == :new,
                do: "destination.create",
                else: "destination.update"
              ),
              "destination",
              destination.id,
              %{"name" => destination.name}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Webhook saved."))
             |> assign(:form, nil)
             |> assign(:editing_destination_id, nil)
             |> load_data()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset, as: :destination))}
        end

      {:error, :not_json} ->
        changeset =
          base
          |> Observability.change_destination(Map.drop(destination_params, ["headers"]))
          |> Ecto.Changeset.put_change(:headers, Map.get(destination_params, "headers"))
          |> Ecto.Changeset.add_error(:headers, "is invalid")

        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Could not save the webhook: the headers are not valid JSON.")
         )
         |> assign(:form, to_form(changeset, as: :destination))}
    end
  end

  defp decode_headers(nil), do: {:ok, %{}}
  defp decode_headers(headers) when is_map(headers), do: {:ok, headers}

  defp decode_headers(headers) when is_binary(headers) do
    if String.trim(headers) == "" do
      {:ok, %{}}
    else
      case Jason.decode(headers) do
        {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
        _ -> {:error, :not_json}
      end
    end
  end

  defp decode_headers(_), do: {:error, :not_json}

  # `editing_destination_id` is either `:new`, nil (cancelled) or the id of the
  # destination being edited; a stale/forged/vanished id must not raise.
  defp destination_base(%{assigns: %{editing_destination_id: nil}}), do: :cancelled
  defp destination_base(%{assigns: %{editing_destination_id: :new}}), do: {:ok, %Destination{}}

  defp destination_base(%{assigns: %{editing_destination_id: id}}) do
    case fetch_destination(id) do
      {:ok, destination} -> {:ok, destination}
      :error -> :missing
    end
  end

  defp fetch_destination(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Destination{} = destination <- Observability.get_destination(uuid) do
      {:ok, destination}
    else
      _ -> :error
    end
  end

  defp fetch_destination(_), do: :error

  ## Template helpers -----------------------------------------------------

  # The `headers` destination field is a :map column, but the form edits it as
  # a JSON string in a textarea. Convert the map to JSON for display; empty
  # maps render as an empty textarea. Invalid JSON submitted previously is
  # stored as %{"_raw" => original} — show the original string back.
  defp headers_to_string(%{} = headers) when map_size(headers) == 0, do: ""

  defp headers_to_string(%{} = headers) do
    case Map.get(headers, "_raw") do
      nil -> Jason.encode!(headers, pretty: true)
      raw -> raw
    end
  end

  # A rejected submit keeps the typed text in the textarea (the changeset holds
  # it as a string so the operator can fix it).
  defp headers_to_string(headers) when is_binary(headers), do: headers

  defp headers_to_string(_), do: ""

  defp stats_for(delivery_stats, id) do
    Map.get(delivery_stats, id, %{completed: 0, pending: 0, failed: 0, last_error: nil})
  end

  defp header_key_names(%{} = headers) when map_size(headers) > 0 do
    headers |> Map.keys() |> Enum.reject(&(&1 == "_raw")) |> Enum.sort()
  end

  defp header_key_names(_), do: []

  ## Render ----------------------------------------------------------------

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
          {gettext("Observability")}
          <:subtitle>
            {gettext("Telemetry webhooks (OTLP) of the whole installation, in one place")}
          </:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-2">
              <.admin_search
                event="search"
                value={@search}
                placeholder={gettext("Search name or URL…")}
                input_id="observability-search-input"
              />
              <.button phx-click="new_destination" id="new-destination-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New webhook")}
              </.button>
            </div>
          </:actions>
        </.header>

        <%!-- Destination form (create / edit) — modal --%>
        <.modal
          :if={@form}
          id="destination-form-modal"
          title={
            if @editing_destination_id == :new,
              do: gettext("New webhook"),
              else: gettext("Edit webhook")
          }
          on_close="cancel_form"
        >
          <.form
            for={@form}
            id="destination-form"
            phx-change="validate_destination"
            phx-submit="save_destination"
          >
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Name")}
              hint={gettext("Identifying name of the webhook. E.g. “Datadog - Production”.")}
            />
            <.input
              field={@form[:url]}
              type="url"
              label="URL"
              placeholder="https://collector.example.com/v1/traces"
              hint={gettext("HTTP(S) endpoint where the telemetry data will be sent (OTLP format).")}
            />
            <.input
              field={@form[:headers]}
              value={headers_to_string(@form[:headers].value)}
              type="textarea"
              label={gettext("Headers (JSON)")}
              placeholder='{"Authorization": "Bearer xxx"}'
              hint={
                gettext(
                  "Extra HTTP headers as JSON. Leave it empty when no extra headers are needed."
                )
              }
            />
            <.input
              field={@form[:enabled]}
              type="checkbox"
              label={gettext("Active (receive telemetry exports)")}
            />
            <div class="flex gap-2 mt-4 justify-end">
              <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary btn-sm" id="save-destination-btn">
                {gettext("Save")}
              </button>
            </div>
          </.form>
        </.modal>

        <.admin_delete_modal
          :if={@delete_target}
          id="delete-destination-modal"
          on_close="cancel_delete"
          title={gettext("Delete webhook?")}
          target_label={@delete_target.name}
          target_span_id="delete-destination-target-name"
          confirm_event="delete_destination"
          confirm_value={@delete_target.id}
          confirm_button_id="confirm-delete-destination-btn"
          cancel_button_id="cancel-delete-destination-btn"
          warning_title={gettext("Telemetry delivery to this endpoint will stop immediately.")}
        />

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="destinations"
            rows={@streams.destinations}
            row_item={fn {_id, destination} -> destination end}
            empty?={@destinations_empty?}
          >
            <:col :let={destination} label={gettext("Webhook")}>
              <div class="flex items-center gap-2">
                <.icon name="hero-bell-alert" class="w-4 h-4 text-primary shrink-0" />
                <div>
                  <div class="font-medium text-sm">{destination.name}</div>
                  <div
                    :if={header_key_names(destination.headers) != []}
                    class="text-[11px] text-base-content/50"
                  >
                    {gettext("Headers:")}
                    <span class="font-mono">
                      {Enum.join(header_key_names(destination.headers), ", ")}
                    </span>
                  </div>
                </div>
              </div>
            </:col>
            <:col :let={destination} label={gettext("Type")}>
              <span class="badge badge-sm badge-primary badge-soft">
                {destination.type}
              </span>
            </:col>
            <:col :let={destination} label="URL">
              <p class="max-w-xs text-xs text-base-content/50 truncate" title={destination.url}>
                {destination.url}
              </p>
            </:col>
            <:col :let={destination} label={gettext("Status")}>
              <button
                type="button"
                phx-click="toggle_destination"
                phx-value-id={destination.id}
                id={"toggle-destination-#{destination.id}"}
                class={[
                  "badge badge-sm cursor-pointer",
                  if(destination.enabled, do: "badge-success", else: "badge-ghost")
                ]}
                title={
                  if(destination.enabled,
                    do: gettext("Click to pause deliveries"),
                    else: gettext("Click to resume deliveries")
                  )
                }
              >
                {if destination.enabled, do: gettext("Active"), else: gettext("Paused")}
              </button>
            </:col>
            <:col :let={destination} label={gettext("24h Deliveries")}>
              <% st = stats_for(@delivery_stats, destination.id) %>
              <div class="flex items-center gap-1.5 text-xs tabular-nums">
                <span class="badge badge-xs badge-success badge-soft" title={gettext("Delivered")}>
                  {st.completed} ok
                </span>
                <span
                  :if={st.pending > 0}
                  class="badge badge-xs badge-warning badge-soft"
                  title={gettext("Pending / retrying")}
                >
                  {st.pending} {gettext("pend")}
                </span>
                <span
                  :if={st.failed > 0}
                  class="badge badge-xs badge-error"
                  title={st.last_error || gettext("Discarded / failed")}
                >
                  {st.failed} {gettext("err")}
                </span>
              </div>
            </:col>
            <:action :let={destination}>
              <button
                type="button"
                phx-click="test_destination"
                phx-value-id={destination.id}
                class="btn btn-xs btn-ghost"
                id={"test-destination-#{destination.id}"}
                title={gettext("Send test payload")}
              >
                <.icon name="hero-bolt" class="w-3.5 h-3.5" />
              </button>
              <button
                type="button"
                phx-click="edit_destination"
                phx-value-id={destination.id}
                class="btn btn-xs btn-ghost"
                id={"edit-destination-#{destination.id}"}
                title={gettext("Edit webhook")}
              >
                <.icon name="hero-pencil" class="w-3.5 h-3.5" />
              </button>
              <button
                type="button"
                phx-click="confirm_delete"
                phx-value-id={destination.id}
                class="btn btn-xs btn-ghost text-error"
                id={"delete-destination-#{destination.id}"}
                title={gettext("Delete webhook")}
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
              </button>
            </:action>
            <:empty>
              <.icon name="hero-bell-slash" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No webhooks configured.")}</p>
            </:empty>
          </.table>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
