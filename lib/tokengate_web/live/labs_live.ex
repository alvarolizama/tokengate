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
      |> assign(:page_title, "Labs · Tokengate")
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:source_filter, "all")
      |> assign(:search, "")
      |> assign(:form, nil)
      |> assign(:editing_key, nil)
      |> assign(:delete_target, nil)
      |> assign(:icon_choices, @icon_choices)
      |> assign(:counts, lab_counts())
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

  defp load_labs(socket) do
    labs =
      Providers.list_labs(
        source: source_opt(socket.assigns.source_filter),
        search: socket.assigns.search
      )

    socket
    |> stream(:labs, labs, reset: true)
    |> assign(:labs_empty?, labs == [])
    |> assign(:counts, lab_counts())
  end

  defp source_opt("all"), do: nil
  defp source_opt(other), do: other

  defp lab_counts do
    %{
      all: length(Providers.list_labs()),
      builtin: length(Providers.list_labs(source: "builtin")),
      custom: length(Providers.list_labs(source: "custom"))
    }
  end

  ## Events — filtros -------------------------------------------------------

  @impl true
  def handle_event("filter_source", %{"source" => source}, socket)
      when source in ~w(all builtin custom) do
    {:noreply, socket |> assign(:source_filter, source) |> load_labs()}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:search, query) |> load_labs()}
  end

  ## Events — form ----------------------------------------------------------

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
    lab = Providers.get_lab!(key)
    changeset = Providers.change_lab(lab)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :lab))
     |> assign(:editing_key, lab.key)}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:editing_key, nil)}
  end

  # El picker es un formulario aparte: cada icono es un botón con el mismo
  # nombre de param, de modo que elegir uno reemplaza al anterior sin JS propio.
  def handle_event("pick_icon", %{"icon" => icon}, socket) when is_binary(icon) do
    form = socket.assigns.form

    changeset = Ecto.Changeset.put_change(form.source, :icon, icon)

    {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
  end

  def handle_event("save_lab", %{"lab" => params}, socket) do
    save_lab(socket, socket.assigns.editing_key, params)
  end

  ## Events — borrado -------------------------------------------------------

  def handle_event("confirm_delete", %{"key" => key}, socket) do
    lab = Providers.get_lab!(key)

    {:noreply,
     socket
     |> assign(:delete_target, lab)
     |> push_event("open_modal", %{id: "delete-lab-modal"})}
  end

  # `admin_delete_modal` emite el valor por `phx-value-id`, así que el evento
  # llega como "id" aunque el sujeto sea la key del lab.
  def handle_event("delete_lab", %{"id" => key}, socket) do
    lab = Providers.get_lab!(key)

    case Providers.delete_custom_lab(lab) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lab «#{lab.name}» eliminado.")
         |> assign(:delete_target, nil)
         |> load_labs()}

      {:error, :builtin} ->
        {:noreply,
         socket
         |> put_flash(:error, "Un lab de catálogo no se puede eliminar.")
         |> assign(:delete_target, nil)}
    end
  end

  ## Private helpers — save ------------------------------------------------

  defp save_lab(socket, :new, params) do
    case Providers.create_custom_lab(params) do
      {:ok, lab} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lab «#{lab.name}» creado.")
         |> assign(:form, nil)
         |> assign(:editing_key, nil)
         |> load_labs()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
    end
  end

  defp save_lab(socket, key, params) when is_binary(key) do
    lab = Providers.get_lab!(key)

    case Providers.update_custom_lab(lab, params) do
      {:ok, lab} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lab «#{lab.name}» actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_key, nil)
         |> load_labs()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :lab))}
    end
  end

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
          Labs
          <:subtitle>Quién construyó cada modelo. Los builtin vienen de models.dev.</:subtitle>
          <:actions>
            <.button phx-click="new_lab" id="new-lab-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo lab custom
            </.button>
          </:actions>
        </.header>

        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div class="join" id="lab-source-tabs" role="tablist">
            <button
              :for={{label, value} <- source_tabs(@counts)}
              phx-click="filter_source"
              phx-value-source={value}
              class={[
                "join-item btn btn-sm",
                if(@source_filter == value, do: "btn-primary", else: "btn-ghost")
              ]}
              id={"lab-tab-#{value}"}
            >
              {label}
            </button>
          </div>

          <.admin_search
            event="search"
            value={@search}
            placeholder="Buscar por nombre o key…"
            input_id="lab-search"
          />
        </div>

        <%!-- El estado vacío va FUERA del contenedor del stream: phx-update
             solo administra los hijos con id de stream. --%>
        <.admin_empty_state
          :if={@labs_empty?}
          id="labs-empty"
          icon="hero-beaker"
          message={empty_message(@source_filter, @search)}
        />

        <div id="labs" phx-update="stream" class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          <div :for={{dom_id, lab} <- @streams.labs} id={dom_id}>
            <div class="card bg-base-100 border border-base-300 shadow-sm h-full">
              <div class="card-body p-4">
                <div class="flex items-start gap-3">
                  <.lab_mark lab={lab} size="md" id={"lab-mark-#{lab.key}"} />

                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2 flex-wrap">
                      <h3 class="font-semibold truncate" id={"lab-name-#{lab.key}"}>{lab.name}</h3>
                      <.lab_badge lab={lab} id={"lab-badge-#{lab.key}"} />
                    </div>
                    <p class="text-xs text-base-content/50 font-mono truncate">{lab.key}</p>
                  </div>

                  <%!-- Acciones al mismo nivel que el nombre, arriba a la derecha. --%>
                  <%= if lab.source == "custom" do %>
                    <div class="card-actions justify-end shrink-0 -mt-1 -mr-1">
                      <button
                        phx-click="edit_lab"
                        phx-value-key={lab.key}
                        class="btn btn-ghost btn-xs"
                        id={"edit-lab-#{lab.key}"}
                      >
                        <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> Editar
                      </button>
                      <button
                        phx-click="confirm_delete"
                        phx-value-key={lab.key}
                        class="btn btn-ghost btn-xs text-error"
                        id={"delete-lab-#{lab.key}"}
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" /> Eliminar
                      </button>
                    </div>
                  <% end %>
                </div>

                <div class="mt-3 flex items-center gap-4 text-xs text-base-content/60">
                  <span class="flex items-center gap-1">
                    <.icon name="hero-cpu-chip" class="w-3.5 h-3.5" />
                    {lab.model_count} {if lab.model_count == 1, do: "modelo", else: "modelos"}
                  </span>
                  <span :if={lab.last_updated} class="flex items-center gap-1">
                    <.icon name="hero-calendar-days" class="w-3.5 h-3.5" />
                    {lab.last_updated}
                  </span>
                  <span
                    :if={lab.source != "custom"}
                    class="ml-auto text-[11px] uppercase tracking-wide text-base-content/30"
                    title="La identidad de un lab de catálogo la escribe el refresh de models.dev"
                  >
                    De catálogo
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Form modal --%>
      <.admin_modal
        :if={@form}
        id="lab-form-modal"
        on_close="cancel_form"
        width="max-w-2xl"
      >
        <h2 class="text-lg font-semibold mb-1">
          {if @editing_key == :new, do: "Nuevo lab custom", else: "Editar lab"}
        </h2>
        <p class="text-xs text-base-content/60 mb-4">
          El key es el identificador con el que los modelos se unen al lab: minúsculas, sin espacios.
        </p>

        <.form for={@form} id="lab-form" phx-submit="save_lab">
          <div class="grid md:grid-cols-2 gap-x-6">
            <div>
              <.input
                field={@form[:name]}
                type="text"
                label="Nombre"
                placeholder="Mi Laboratorio"
                required
              />
              <.input
                field={@form[:key]}
                type="text"
                label="Key"
                placeholder="mi-lab"
                disabled={@editing_key != :new}
                hint={
                  if @editing_key == :new,
                    do: "Slug único, ej. mi-lab",
                    else: "El key no se puede cambiar: los modelos ya apuntan a él."
                }
              />
              <.input
                field={@form[:logo_url]}
                type="url"
                label="Logo (URL, opcional)"
                placeholder="https://…/logo.svg"
                hint="Si el lab no tiene logo remoto, se usa el icono de abajo."
              />
            </div>

            <div>
              <.input
                field={@form[:icon]}
                type="text"
                label="Icono"
                placeholder="hero-beaker"
                hint="Nombre de hero icon, ej. hero-beaker. Se usa cuando no hay logo."
              />

              <div class="fieldset mb-2">
                <span class="label">Elegir de la paleta</span>
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
                  Se usa cuando no hay logo. El logo, si lo hay, siempre gana.
                </p>
              </div>

              <div class="fieldset">
                <span class="label">Vista previa</span>
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
              Cancelar
            </button>
            <button type="submit" class="btn btn-primary btn-sm" id="save-lab">
              {if @editing_key == :new, do: "Crear lab", else: "Guardar cambios"}
            </button>
          </div>
        </.form>
      </.admin_modal>

      <.admin_delete_modal
        id="delete-lab-modal"
        title="Eliminar lab"
        target_label={@delete_target && @delete_target.name}
        target_span_id="delete-lab-target"
        confirm_event="delete_lab"
        confirm_value={@delete_target && @delete_target.key}
        confirm_button_id="confirm-delete-lab"
        cancel_button_id="cancel-delete-lab"
        warning_title="Se elimina la marca del lab."
        warning_intro="Los modelos no se tocan: sólo dejan de resolver a este lab."
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
    ~H"""
    <span
      id={@id}
      class={[
        "flex items-center justify-center shrink-0 rounded-lg border border-base-300 bg-white overflow-hidden",
        if(@size == "md", do: "w-10 h-10", else: "w-8 h-8")
      ]}
    >
      <%= case Lab.mark(@lab) do %>
        <% {:logo, url} -> %>
          <img src={url} alt="" class="object-contain w-5 h-5" loading="lazy" />
        <% {:icon, icon} -> %>
          <.icon name={icon} class="w-5 h-5 text-base-content/70" />
      <% end %>
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
          do: "models.dev ya no publica este lab",
          else: "Origen y estado del lab"
      }
    >
      {if @lab.status == "stale", do: "obsoleto", else: @lab.source}
    </span>
    """
  end

  ## Helpers ----------------------------------------------------------------

  defp source_tabs(counts) do
    [
      {"Todos (#{counts.all})", "all"},
      {"models.dev (#{counts.builtin})", "builtin"},
      {"Custom (#{counts.custom})", "custom"}
    ]
  end

  defp empty_message("custom", ""), do: "Todavía no hay labs custom. Crea el primero."

  defp empty_message(_source, search) when search != "",
    do: "Ningún lab coincide con «#{search}»."

  defp empty_message(_source, _search), do: "No hay labs que mostrar."

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
