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

  # Sin filtros de ningún tipo: builtin y custom se listan siempre juntos y
  # completos. La pantalla es para ver y administrar labs, no para acotarlos.
  defp load_labs(socket) do
    labs = Providers.list_labs()

    socket
    |> stream(:labs, labs, reset: true)
    |> assign(:labs_empty?, labs == [])
  end

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

    {:noreply, assign(socket, :delete_target, lab)}
  end

  # Cerrar la confirmación (✕, Escape o click-away) olvida el objetivo.
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  # `admin_delete_modal` emite el valor por `phx-value-id`, así que el evento
  # llega como "id" aunque el sujeto sea la key del lab.
  def handle_event("delete_lab", %{"id" => key}, socket) do
    lab = Providers.get_lab!(key)

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
    lab = Providers.get_lab!(key)

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
          {gettext("Labs")}
          <:subtitle>{gettext("Who built each model. Builtins come from models.dev.")}</:subtitle>
          <:actions>
            <.button phx-click="new_lab" id="new-lab-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo lab custom
            </.button>
          </:actions>
        </.header>

        <%!-- El estado vacío va FUERA del contenedor del stream: phx-update
             solo administra los hijos con id de stream. --%>
        <.empty_state
          :if={@labs_empty?}
          id="labs-empty"
          icon="hero-beaker"
          title={gettext("No labs to show.")}
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
                    {lab.model_count} {if lab.model_count == 1,
                      do: gettext("model"),
                      else: gettext("models")}
                  </span>
                  <span :if={lab.last_updated} class="flex items-center gap-1">
                    <.icon name="hero-calendar-days" class="w-3.5 h-3.5" />
                    {lab.last_updated}
                  </span>
                  <span
                    :if={lab.source != "custom"}
                    class="ml-auto text-[11px] uppercase tracking-wide text-base-content/30"
                    title={gettext("A catalog lab identity is written by the models.dev refresh")}
                  >
                    {gettext("From catalog")}
                  </span>
                </div>
              </div>
            </div>
          </div>
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

        <.form for={@form} id="lab-form" phx-submit="save_lab">
          <div class="grid md:grid-cols-2 gap-x-6">
            <div>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder="Mi Laboratorio"
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
                label="Logo (URL, opcional)"
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
          <.icon name={icon} class="w-5 h-5 text-neutral-600" />
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
          do: gettext("models.dev no longer publishes this lab"),
          else: gettext("Lab source and status")
      }
    >
      {if @lab.status == "stale", do: "obsoleto", else: @lab.source}
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
