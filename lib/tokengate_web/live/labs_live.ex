defmodule TokengateWeb.LabsLive do
  @moduledoc """
  Catálogo de labs: los builtin de models.dev y los custom del operador.

  Un lab es quién construyó el modelo (Anthropic, DeepSeek, Qwen…), no quién
  lo sirve. Los builtin son de solo lectura: `name`, `logo_url` y `model_count`
  los escribe el refresh; editar su identidad desde aquí no tendría efecto,
  así que la UI ni lo ofrece.

  La página existe por los labs **custom**: uno que models.dev no publica
  necesita igual un nombre, un key con el que unirse y una marca que mostrar.
  Esa marca es el `icon`: un hero icon elegido de una paleta, usado cuando no
  hay `logo_url` (o cuando el logo remoto no carga). El logo, si se pone, gana.
  """

  use TokengateWeb, :live_view

  import TokengateWeb.AdminComponents

  alias Tokengate.Providers
  alias Tokengate.Providers.{Lab, LabCatalog}

  # Paleta del picker: los iconos que hacen sentido como marca de un lab.
  # Es una lista curada a propósito — abrir las ~300 del set no ayuda a nadie,
  # y cualquiera del set sigue siendo válido por changeset (se escribe a mano).
  @icon_choices ~w(
    hero-beaker hero-sparkles hero-cube hero-cpu-chip hero-globe-alt
    hero-academic-cap hero-light-bulb hero-rocket-launch hero-fire hero-bolt
    hero-circle-stack hero-squares-2x2 hero-command-line hero-window
    hero-paint-brush hero-wrench-screwdriver
  )

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    socket =
      socket
      |> assign(:page_title, gettext("Labs") <> " · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:form, nil)
      |> assign(:editing_key, nil)
      |> assign(:delete_target, nil)
      |> assign(:icon_choices, @icon_choices)
      |> assign(:search_query, "")
      |> assign(:filter_source, "all")
      |> assign(:sort_field, :name)
      |> assign(:sort_direction, :asc)
      |> assign(:all_labs, [])
      |> require_admin_hook()
      |> stream_configure(:labs, dom_id: &"lab-#{&1.key}")
      |> load_labs()

    {:ok, socket}
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

  @lab_sort_fields %{
    "name" => :name,
    "source" => :source,
    "model_count" => :model_count,
    "last_updated" => :last_updated
  }

  defp load_labs(socket) do
    labs = Providers.list_labs()

    socket
    |> assign(:all_labs, labs)
    |> stream_labs()
  end

  defp stream_labs(socket) do
    labs =
      socket.assigns.all_labs
      |> filter_labs_by_source(socket.assigns.filter_source)
      |> filter_labs_by_query(socket.assigns.search_query)
      |> sort_labs(socket.assigns.sort_field, socket.assigns.sort_direction)

    socket
    |> stream(:labs, labs, reset: true)
    |> assign(:labs_empty?, labs == [])
  end

  defp filter_labs_by_source(labs, "all"), do: labs

  defp filter_labs_by_source(labs, source) when source in ~w(custom builtin) do
    Enum.filter(labs, &(&1.source == source))
  end

  defp filter_labs_by_source(labs, _other), do: labs

  defp filter_labs_by_query(labs, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    if needle == "" do
      labs
    else
      Enum.filter(labs, fn lab ->
        String.contains?(String.downcase(lab.name || ""), needle) or
          String.contains?(String.downcase(lab.key || ""), needle)
      end)
    end
  end

  defp sort_labs(labs, field, direction) do
    Enum.sort_by(
      labs,
      fn lab -> {lab_sort_value(lab, field), String.downcase(lab.name || "")} end,
      fn {val_a, name_a}, {val_b, name_b} ->
        cond do
          val_a == val_b -> name_a <= name_b
          direction == :asc -> val_a < val_b
          true -> val_a > val_b
        end
      end
    )
  end

  defp lab_sort_value(lab, :name), do: String.downcase(lab.name || "")
  defp lab_sort_value(lab, :source), do: lab.source || ""
  defp lab_sort_value(lab, :model_count), do: lab.model_count || 0
  defp lab_sort_value(lab, :last_updated), do: lab.last_updated || ""

  ## Events — form ----------------------------------------------------------

  @impl true
  def handle_event("new_lab", _params, socket) do
    changeset =
      Providers.change_lab(%Lab{})
      |> Ecto.Changeset.put_change(:icon, LabCatalog.default_icon())

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :lab))
     |> assign(:editing_key, :new)}
  end

  def handle_event("edit_lab", %{"key" => key}, socket) do
    case custom_lab(key, :edit) do
      {:ok, lab} ->
        changeset = Providers.change_lab(lab)

        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: :lab))
         |> assign(:editing_key, lab.key)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:editing_key, nil)}
  end

  # Every keystroke is tracked in the changeset. Without this the form is
  # client-only state and the NEXT server render (picking a palette icon, for
  # one) repaints the persisted values, silently wiping the name/logo the
  # operator just typed.
  def handle_event("validate_lab", %{"lab" => params}, socket) do
    case socket.assigns.form do
      nil ->
        {:noreply, socket}

      form ->
        changeset =
          form.source.data
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.cast(params, [:name, :key, :logo_url, :icon])

        {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
    end
  end

  def handle_event("validate_lab", _params, socket), do: {:noreply, socket}

  # El picker es un formulario aparte: cada icono es un botón con el mismo
  # nombre de param, de modo que elegir uno reemplaza al anterior sin JS propio.
  def handle_event("pick_icon", %{"icon" => icon}, socket) when is_binary(icon) do
    case socket.assigns.form do
      nil ->
        {:noreply, socket}

      form ->
        changeset = Ecto.Changeset.put_change(form.source, :icon, icon)
        {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
    end
  end

  def handle_event("save_lab", %{"lab" => params}, socket) do
    save_lab(socket, socket.assigns.editing_key, params)
  end

  def handle_event("save_lab", _params, socket), do: {:noreply, socket}

  ## Events — borrado -------------------------------------------------------

  def handle_event("confirm_delete", %{"key" => key}, socket) do
    case custom_lab(key, :delete) do
      {:ok, lab} ->
        {:noreply, assign(socket, :delete_target, lab)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Cerrar la confirmación (✕, Escape o click-away) olvida el objetivo.
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  # `admin_delete_modal` emite el valor por `phx-value-id`, así que el evento
  # llega como "id" aunque el sujeto sea la key del lab.
  def handle_event("delete_lab", %{"id" => key}, socket) do
    lab = Providers.get_lab(key)

    cond do
      is_nil(lab) ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That lab does not exist."))
         |> assign(:delete_target, nil)}

      true ->
        case Providers.delete_custom_lab(lab) do
          {:ok, _} ->
            audit(socket, "lab.delete", "lab", lab.key, %{"name" => lab.name})

            {:noreply,
             socket
             |> put_flash(:info, gettext("Lab “%{name}” deleted.", name: lab.name))
             |> assign(:delete_target, nil)
             |> load_labs()}

          {:error, :builtin} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("A catalog lab cannot be deleted."))
             |> assign(:delete_target, nil)}
        end
    end
  end

  def handle_event("search_labs", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> stream_labs()}
  end

  def handle_event("search_labs", %{"value" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> stream_labs()}
  end

  def handle_event("filter_lab_source", %{"source" => source}, socket)
      when source in ~w(all custom builtin) do
    {:noreply,
     socket
     |> assign(:filter_source, source)
     |> stream_labs()}
  end

  def handle_event("sort_labs", %{"field" => field}, socket) do
    case Map.fetch(@lab_sort_fields, field) do
      {:ok, sort_atom} ->
        {sort_field, sort_direction} =
          if socket.assigns.sort_field == sort_atom do
            {sort_atom, if(socket.assigns.sort_direction == :asc, do: :desc, else: :asc)}
          else
            default_dir = if sort_atom in [:model_count, :last_updated], do: :desc, else: :asc
            {sort_atom, default_dir}
          end

        {:noreply,
         socket
         |> assign(:sort_field, sort_field)
         |> assign(:sort_direction, sort_direction)
         |> stream_labs()}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Private helpers — save ------------------------------------------------

  defp save_lab(socket, :new, params) do
    case Providers.create_custom_lab(params) do
      {:ok, lab} ->
        audit(socket, "lab.create", "lab", lab.key, %{"name" => lab.name})

        {:noreply,
         socket
         |> put_flash(:info, gettext("Lab “%{name}” created.", name: lab.name))
         |> assign(:form, nil)
         |> assign(:editing_key, nil)
         |> load_labs()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
    end
  end

  defp save_lab(socket, key, params) when is_binary(key) do
    case custom_lab(key, :edit) do
      {:ok, lab} ->
        case Providers.update_custom_lab(lab, params) do
          {:ok, lab} ->
            audit(socket, "lab.update", "lab", lab.key, %{"name" => lab.name})

            {:noreply,
             socket
             |> put_flash(:info, gettext("Lab “%{name}” updated.", name: lab.name))
             |> assign(:form, nil)
             |> assign(:editing_key, nil)
             |> load_labs()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign(:form, nil)
         |> assign(:editing_key, nil)}
    end
  end

  ## Private helpers — lookup ----------------------------------------------

  # A lab key comes from the client (a `phx-value-key`), so it is never trusted:
  # an unknown key answers with a flash instead of raising `NoResultsError` and
  # killing the LiveView. Builtins are catalog-owned here — only custom labs can
  # be edited or deleted.
  defp custom_lab(key, action) do
    case Providers.get_lab(key) do
      nil ->
        {:error, gettext("That lab does not exist.")}

      %Lab{source: "custom"} = lab ->
        {:ok, lab}

      %Lab{} ->
        {:error, catalog_lab_message(action)}
    end
  end

  defp catalog_lab_message(:delete), do: gettext("A catalog lab cannot be deleted.")
  defp catalog_lab_message(_action), do: gettext("A catalog lab cannot be edited.")

  ## Render -----------------------------------------------------------------

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
          {gettext("Labs")}
          <:subtitle>{gettext("Who built each model. Builtins come from models.dev.")}</:subtitle>
          <:actions>
            <div class="flex flex-wrap items-center gap-3">
              <.admin_search
                event="search_labs"
                value={@search_query}
                placeholder={gettext("Search by name or key…")}
                input_id="lab-search"
              />
              <.button phx-click="new_lab" id="new-lab-btn">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New custom lab")}
              </.button>
            </div>
          </:actions>
        </.header>

        <div class="flex flex-wrap items-center gap-1.5" id="lab-filter-pills">
          <button
            :for={
              {source, label} <- [
                {"all", gettext("All")},
                {"custom", gettext("Custom")},
                {"builtin", gettext("Builtin")}
              ]
            }
            type="button"
            phx-click="filter_lab_source"
            phx-value-source={source}
            id={"filter-lab-source-#{source}"}
            class={[
              "btn btn-xs",
              if(@filter_source == source, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {label}
          </button>
        </div>

        <div class="overflow-x-auto card bg-base-100 border border-base-300 shadow-sm">
          <.table
            id="labs"
            rows={@streams.labs}
            row_item={fn {_id, lab} -> lab end}
            row_class="align-top"
            sort_field={@sort_field}
            sort_direction={@sort_direction}
            sort_event="sort_labs"
            empty?={@labs_empty?}
          >
            <:col :let={lab} label={gettext("Lab")} field={:name}>
              <div class="flex items-center gap-3">
                <.lab_mark lab={lab} size="sm" id={"lab-mark-#{lab.key}"} />
                <div class="min-w-0">
                  <p class="font-semibold truncate" id={"lab-name-#{lab.key}"}>{lab.name}</p>
                  <p class="text-xs text-base-content/50 font-mono truncate">{lab.key}</p>
                </div>
              </div>
            </:col>
            <:col :let={lab} label={gettext("Source")} field={:source}>
              <.lab_badge lab={lab} id={"lab-badge-#{lab.key}"} />
            </:col>
            <:col :let={lab} label={gettext("Models")} field={:model_count} align="right">
              <.link
                navigate={~p"/catalog/models?#{[q: lab.key]}"}
                class="link link-hover inline-flex items-center gap-1 whitespace-nowrap"
                id={"lab-models-#{lab.key}"}
                title={gettext("View models from this lab")}
              >
                <.icon name="hero-cpu-chip" class="w-3.5 h-3.5" />
                <span>
                  {lab.model_count} {if lab.model_count == 1,
                    do: gettext("model"),
                    else: gettext("models")}
                </span>
              </.link>
            </:col>
            <:col :let={lab} label={gettext("Updated")} field={:last_updated}>
              <span :if={lab.last_updated} class="text-xs text-base-content/60 font-mono">
                {lab.last_updated}
              </span>
              <span :if={!lab.last_updated} class="text-base-content/30">—</span>
            </:col>
            <:action :let={lab}>
              <%= if lab.source == "custom" do %>
                <button
                  phx-click="edit_lab"
                  phx-value-key={lab.key}
                  class="btn btn-xs btn-ghost"
                  id={"edit-lab-#{lab.key}"}
                  title={gettext("Edit")}
                  aria-label={gettext("Edit")}
                >
                  <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
                </button>
                <button
                  phx-click="confirm_delete"
                  phx-value-key={lab.key}
                  class="btn btn-xs btn-ghost text-error"
                  id={"delete-lab-#{lab.key}"}
                  title={gettext("Delete")}
                  aria-label={gettext("Delete")}
                >
                  <.icon name="hero-trash" class="w-3.5 h-3.5" />
                </button>
              <% else %>
                <span
                  class="text-[11px] uppercase tracking-wide text-base-content/30 whitespace-nowrap"
                  title={gettext("A catalog lab identity is written by the models.dev refresh")}
                >
                  {gettext("From catalog")}
                </span>
              <% end %>
            </:action>
            <:empty>
              <.icon name="hero-beaker" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No labs to show.")}</p>
            </:empty>
          </.table>
        </div>
      </div>

      <%!-- Form modal --%>
      <.modal
        :if={@form}
        id="lab-form-modal"
        title={if @editing_key == :new, do: gettext("New custom lab"), else: gettext("Edit lab")}
        on_close="cancel_form"
        max_w="max-w-2xl"
      >
        <p class="text-xs text-base-content/60 mb-4">
          {gettext("The key is the identifier models join the lab by: lowercase, no spaces.")}
        </p>

        <.form for={@form} id="lab-form" phx-change="validate_lab" phx-submit="save_lab">
          <div class="grid md:grid-cols-2 gap-x-6">
            <div>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("My Lab")}
                required
              />
              <.input
                field={@form[:key]}
                type="text"
                label="Key"
                placeholder={gettext("my-lab")}
                disabled={@editing_key != :new}
                hint={
                  if @editing_key == :new,
                    do: gettext("Unique slug, e.g. my-lab"),
                    else: gettext("The key cannot be changed: models already point to it.")
                }
              />
              <.input
                field={@form[:logo_url]}
                type="url"
                label={gettext("Logo (URL, optional)")}
                placeholder="https://…/logo.svg"
                hint={gettext("If the lab has no remote logo, the icon below is used.")}
              />
            </div>

            <div>
              <.input
                field={@form[:icon]}
                type="text"
                label={gettext("Icon")}
                placeholder="hero-beaker"
                hint={gettext("Hero icon name, e.g. hero-beaker. Used when there is no logo.")}
              />

              <div class="fieldset mb-2">
                <span class="label">{gettext("Pick from the palette")}</span>
                <div class="grid grid-cols-8 gap-1" id="lab-icon-picker">
                  <button
                    :for={icon <- @icon_choices}
                    type="button"
                    phx-click="pick_icon"
                    phx-value-icon={icon}
                    class={[
                      "flex items-center justify-center rounded-lg border p-1.5 transition-colors",
                      if(@form[:icon].value == icon,
                        do: "border-primary bg-primary/10 text-primary",
                        else: "border-base-300 hover:bg-base-200"
                      )
                    ]}
                    id={"icon-choice-#{icon}"}
                    title={icon}
                  >
                    <.icon name={icon} class="w-4 h-4" />
                  </button>
                </div>
                <p class="text-xs text-base-content/50 mt-1">
                  {gettext("Used when there is no logo. The logo, when present, always wins.")}
                </p>
              </div>

              <div class="fieldset">
                <span class="label">{gettext("Preview")}</span>
                <div
                  class="flex items-center justify-center rounded-lg border border-base-300 bg-base-200/40 h-16"
                  id="lab-mark-preview"
                >
                  <.lab_mark lab={preview_lab(@form)} size="md" id="lab-mark-preview-inner" />
                </div>
              </div>
            </div>
          </div>

          <div class="flex justify-end gap-2 mt-6">
            <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm" id="cancel-lab">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm" id="save-lab">
              {if @editing_key == :new, do: gettext("Create lab"), else: gettext("Save changes")}
            </button>
          </div>
        </.form>
      </.modal>

      <.admin_delete_modal
        :if={@delete_target}
        id="delete-lab-modal"
        on_close="cancel_delete"
        title={gettext("Delete lab")}
        target_label={@delete_target.name}
        target_span_id="delete-lab-target"
        confirm_event="delete_lab"
        confirm_value={@delete_target.key}
        confirm_button_id="confirm-delete-lab"
        cancel_button_id="cancel-delete-lab"
        warning_title={gettext("The lab mark is deleted.")}
        warning_intro={gettext("Models are not touched: they just stop resolving to this lab.")}
      />
    </Layouts.dashboard>
    """
  end

  ## Componentes ------------------------------------------------------------

  # La marca del lab: logo remoto si lo hay, si no el icono. `Lab.mark/1` es
  # la única definición de esa precedencia, así que la UI no la reimplementa.
  attr :lab, :map, required: true
  attr :size, :string, default: "sm"
  attr :id, :string, required: true

  defp lab_mark(assigns) do
    logo =
      case Lab.mark(assigns.lab) do
        {:logo, url} -> url
        _ -> nil
      end

    icon =
      case assigns.lab.icon do
        i when is_binary(i) and i != "" -> i
        _ -> LabCatalog.default_icon()
      end

    assigns = assign(assigns, logo: logo, icon: icon)

    ~H"""
    <span
      id={@id}
      class={[
        "flex items-center justify-center shrink-0 rounded-lg border border-base-300 bg-white overflow-hidden",
        if(@size == "md", do: "w-10 h-10", else: "w-8 h-8")
      ]}
    >
      <img
        :if={@logo}
        src={@logo}
        alt=""
        data-logo
        class="object-contain w-5 h-5"
        loading="lazy"
      />
      <.icon
        name={@icon}
        class={["w-5 h-5 text-neutral-600", @logo && "hidden"]}
      />
    </span>
    """
  end

  attr :lab, :map, required: true
  attr :id, :string, required: true

  defp lab_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "badge badge-xs",
        if(@lab.source == "custom", do: "badge-primary", else: "badge-ghost"),
        @lab.status == "stale" && "badge-warning"
      ]}
      title={
        if @lab.status == "stale",
          do: gettext("models.dev no longer publishes this lab"),
          else: gettext("Lab source and status")
      }
    >
      {if @lab.status == "stale", do: gettext("stale"), else: @lab.source}
    </span>
    """
  end

  ## Helpers ----------------------------------------------------------------

  # El changeset no trae `model_count`/`source`/`status` (son del catálogo), así
  # que la vista previa los rellena para que `Lab.mark/1` pueda decidir.
  defp preview_lab(form) do
    %Lab{
      name: form[:name].value || "",
      logo_url: form[:logo_url].value || nil,
      icon: form[:icon].value || nil,
      source: "custom",
      status: "active"
    }
  end
end
