defmodule TokengateWeb.ModelsLive do
  @moduledoc """
  El catálogo de modelos como TABLA: una fila por modelo.

  Aquí vive lo que el modelo ES (nombre, tipo, contexto, lab/icono, guard
  rails) y el alta completa (wizard proveedor → modelo → datos). Lo que hace que
  el modelo sea ruteable — las API keys que lo sirven, con su prioridad,
  alcance y precio — vive en `TokengateWeb.ModelProvidersLive`
  (`/catalog/models/:id`).

  La tabla no consulta por fila: `aliases_with_providers_query/0` trae los
  modelos con sus lanes precargadas en UNA query y los contadores
  (`lane_count/1`, `lane_provider_count/1`, `price_summary/1`) se calculan en
  memoria sobre eso.

  ## Cost model

  The primary cost source is the upstream provider's `usage.cost` report.
  Manual per-provider pricing (input + cache + output per million tokens)
  serves as a fallback when the upstream omits cost. Every provider is
  priced by the same chain (upstream report → manual pricing → $0), with no
  billing-surface exemption.

  ## Exclusive scope

  A model_provider can be scoped to serve only specific consumers:
    * Global — available to all group members with access.
    * Member-exclusive — only the specified group member sees it.
    * Group-exclusive — only members of the specified group see it.
  """
  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]

  # Las piezas compartidas con la página del modelo (descubrimiento de modelos
  # del proveedor, dom_key, máscara de key, formatters) viven en ModelPicker.
  import TokengateWeb.ModelPicker,
    except: [
      dom_key: 1,
      list_provider_models: 3,
      model_type_for: 1,
      type_endpoint: 1,
      type_endpoint_pairs: 0
    ]

  alias Tokengate.Providers
  alias TokengateWeb.ModelPicker

  # Reexportadas: son el contrato que los tests citan de este módulo.
  defdelegate dom_key(key), to: ModelPicker
  defdelegate list_provider_models(provider, credential, type), to: ModelPicker
  defdelegate model_type_for(model_id), to: ModelPicker
  defdelegate type_endpoint(type), to: ModelPicker
  defdelegate type_endpoint_pairs(), to: ModelPicker

  alias Tokengate.Providers.{Lab, Model, ModelIds, ModelProvider, Pricing, ServiceModels}

  alias Tokengate.Repo

  # Paleta del picker de icono: la misma lista curada que el modal de labs
  # (`LabsLive.@icon_choices`) — una marca de modelo hace el mismo trabajo que
  # una de lab. Cualquier otro hero icon sigue siendo válido por changeset (el
  # campo de texto lo acepta).
  @icon_choices ~w(
    hero-beaker hero-sparkles hero-cube hero-cpu-chip hero-globe-alt
    hero-academic-cap hero-light-bulb hero-rocket-launch hero-fire hero-bolt
    hero-circle-stack hero-squares-2x2 hero-command-line hero-window
    hero-paint-brush hero-wrench-screwdriver
  )

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = user && user.global_role == "admin"

    socket =
      socket
      |> assign(:page_title, gettext("Models") <> " · Tokengate")
      |> assign(:is_admin, is_admin)
      |> assign(:form, nil)
      |> assign(:editing_model_id, nil)
      |> assign(:guard_rails_form, nil)
      |> assign(:guard_rails_model_id, nil)
      |> assign(:provider_form, nil)
      |> assign(:provider_form_model_id, nil)
      |> assign(:editing_ap_id, nil)
      |> assign(:provider_models, [])
      |> assign(:provider_models_loading, false)
      |> assign(:provider_model_search, "")
      |> assign(:provider_form_credential_id, nil)
      |> assign(:provider_form_is_fireworks, false)
      |> assign(:provider_form_pricing_unit, nil)
      |> assign(:current_scope, "global")
      |> assign(:current_scope_group_ids, [])
      |> assign(:current_scope_member_ids, [])
      |> assign(:scope_group_search, "")
      |> assign(:scope_member_search, "")
      |> assign(:scope_group_open, false)
      |> assign(:scope_member_open, false)
      |> assign(:labs_by_key, %{})
      |> assign(:lab_choices, [])
      |> assign(:icon_choices, @icon_choices)
      |> assign(:model_form_picked_type, nil)
      |> assign(:type_picker_open, false)
      # Wizard del alta/edición: 1) proveedor (acotado por el tipo), 2) modelo,
      # 3) los datos del modelo. El paso manda en qué se renderiza dentro del
      # mismo modal.
      |> assign(:wizard_step, "provider")
      |> assign(:wizard_providers, [])
      |> assign(:wizard_provider_search, "")
      |> assign(:wizard_provider_key, nil)
      |> assign(:wizard_provider_label, nil)
      |> assign(:wizard_models, [])
      |> assign(:wizard_provider_model, nil)
      |> assign(:wizard_credential_id, nil)
      |> assign(:wizard_credentials, [])
      |> assign(:wizard_credential_label, nil)
      |> assign(:wizard_models_loading, false)
      |> assign(:wizard_models_error, nil)
      |> assign(:wizard_lanes, [])
      |> assign(:provider_choices, [])
      |> assign(:provider_search, "")
      |> assign(:provider_choices_results, [])
      |> assign(:provider_form_provider_key, nil)
      |> assign(:provider_credentials, nil)
      |> assign(:credential_form, nil)
      |> load_models()
      |> load_labs()
      |> assign_form_data()
      |> assign_credential_choices()
      |> assign_scope_data()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  # Un id de modelo que llega del cliente se castea ANTES de tocar la DB: uno que
  # ni siquiera es UUID revienta con CastError y uno inexistente con
  # NoResultsError, y los dos se llevan la LiveView. `nil` es el "nada que hacer"
  # que todos los handlers de abajo comparten.
  defp fetch_model(model_id) do
    with {:ok, id} <- Ecto.UUID.cast(model_id) do
      Providers.get_model(id)
    else
      _ -> nil
    end
  end

  # Una lane por id de cliente (`edit_model_provider_from_modal`): cast + fila
  # real, nunca `get_model_provider!/1` sobre un payload.
  defp fetch_lane(ap_id) do
    with {:ok, id} <- Ecto.UUID.cast(ap_id) do
      Providers.get_model_provider(id)
    else
      _ -> nil
    end
  end

  # Una fila por modelo: el stream lleva SÓLO modelos (el `.table` dibuja un
  # `<tr>` por item y no sabe de filas separadoras). La etiqueta de la sección
  # viaja en `@model_sections` (model.id → meta) y la pinta la primera celda del
  # modelo que abre el grupo.
  defp load_models(socket) do
    models =
      aliases_with_providers_query()
      |> Repo.all()
      # El SQL deja el orden de los LANES precargados por modelo (scope →
      # priority); el orden de la LISTA es visual y va aquí: Fijados primero,
      # luego cada tipo en orden canónico, alfabético dentro del grupo.
      |> Enum.sort_by(&{not &1.pinned, type_rank(&1.model_type), String.downcase(&1.name)})

    socket
    |> stream(:models, models, reset: true, dom_id: & &1.id)
    |> assign(:model_sections, model_group_headers(models))
    |> assign(:models_empty?, models == [])
  end

  # -- Agrupación del listado por tipo ---------------------------------------
  #
  # El stream es UNA lista plana de modelos y `.table` dibuja un `<tr>` por
  # item (sin filas separadoras ni colspan), así que la agrupación visual viaja
  # como `model.id → meta`: la primera celda del modelo que abre sección pinta
  # la etiqueta del grupo con su conteo. No hay filtro: el listado sigue
  # completo.

  # Orden canónico de tipos = el del picker de alta (`model_type_choices/0`),
  # crudo porque un atributo de módulo no puede evaluar gettext.
  @type_order ~w(llm embedding decision stt tts image)

  defp type_rank(type), do: Enum.find_index(@type_order, &(&1 == type)) || length(@type_order)

  # 1er pase: conteo por sección (pinned es sección propia; el resto su tipo).
  # 2o pase: el PRIMER modelo de cada sección abre el separador — la marca es
  # por KEY DE SECCIÓN, no por model id (dos filas nunca comparten id, pero
  # todas las de un grupo sí comparten sección: el check equivocado duplicaría
  # el separador —y su DOM id— en cada fila del grupo).
  defp model_group_headers(models) do
    counts = Enum.frequencies_by(models, &section_key/1)

    {meta_list, _seen} =
      Enum.map_reduce(models, %{}, fn model, seen ->
        key = section_key(model)

        if Map.has_key?(seen, key) do
          {nil, seen}
        else
          {section_meta(key, Map.fetch!(counts, key)), Map.put(seen, key, true)}
        end
      end)

    models
    |> Enum.zip(meta_list)
    |> Map.new(fn {model, meta} -> {model.id, meta} end)
  end

  defp section_key(%{pinned: true}), do: :pinned
  defp section_key(%{model_type: type}), do: type

  defp section_meta(:pinned, count) do
    %{type: "pinned", label: gettext("Pinned"), icon: "hero-star-solid", count: count}
  end

  defp section_meta(type, count) do
    case Enum.find(model_type_choices(), fn {_, t, _} -> t == type end) do
      {label, _, icon} ->
        %{type: type, label: label, icon: icon, count: count}

      # La columna tiene CHECK en DB, así que esto sólo dispararía un nil
      # pre-vocabulario: sección genérica al final en vez de reventar el render.
      nil ->
        %{type: "other", label: gettext("Other"), icon: "hero-cpu-chip", count: count}
    end
  end

  # El vínculo modelo→lab es blando (`lab_key`), así que la marca se resuelve
  # contra un índice cargado una vez: los labs se editan en otra página, no
  # aquí. Sin labs no hay selector y todo cae al icono propio.
  defp load_labs(socket) do
    labs = Providers.list_labs()

    socket
    |> assign(:labs_by_key, Map.new(labs, &{&1.key, &1}))
    |> assign(:lab_choices, Enum.map(labs, &{"#{&1.name} (#{&1.key})", &1.key}))
  end

  # Los tipos que el alta ofrece. Un tipo SIN ruta en el gateway (ningún endpoint
  # en `ModelPicker.type_endpoint/1`) es una promesa que nada sirve — el error
  # que el propio catálogo prohíbe (una capability declarada sin superficie).
  # Hoy las seis tienen ruta, así que el filtro es la garantía mecánica: el día
  # que un tipo entre al vocabulario antes que su ruta, no se ofrece.
  def model_type_choices do
    Enum.filter(all_type_choices(), fn {_label, type, _icon} -> type_endpoint(type) != nil end)
  end

  defp all_type_choices do
    [
      {gettext("LLM (chat)"), "llm", "hero-chat-bubble-left-right"},
      {gettext("Embedding"), "embedding", "hero-squares-2x2"},
      {gettext("Decisions"), "decision", "hero-scale"},
      {gettext("Transcription"), "stt", "hero-microphone"},
      {gettext("Speech"), "tts", "hero-speaker-wave"},
      {gettext("Images"), "image", "hero-photo"}
    ]
  end

  # Options of the operator effort-policy selects (`effort_default` /
  # `effort_override`). The empty prompt = no-op, submitted as "" and stored
  # as nil by the changeset.
  defp effort_policy_options do
    Enum.map(Model.effort_levels(), &{String.upcase(&1), &1})
  end

  # Los pasos del alta, en el orden en que se decide todo, para el indicador
  # que pinta `.modal` (`.steps`). Las claves son las mismas de `@wizard_step`:
  # el componente sólo resalta la activa, el avance lo valida el LiveView.
  defp wizard_steps do
    [
      {"provider", gettext("Provider")},
      {"credential", gettext("API key")},
      {"model", gettext("Model")},
      {"details", gettext("Data")}
    ]
  end

  # Providers are grouped by scope first — global, then group-exclusive,
  # then member-exclusive — and ordered by priority within each group.
  defp aliases_with_providers_query do
    from(ma in Model,
      left_join: aps in assoc(ma, :model_providers),
      # El pool entra en el MISMO preload: la fila del modelo lo cuenta y el
      # modal de edición lo pinta. Ningún lane de pool tiene credencial, así
      # que sin este preload su nombre no existiría.
      preload: [
        model_providers: {aps, [credential: :provider, pool: [members: [credential: :provider]]]}
      ],
      order_by: [
        desc: ma.pinned,
        asc: ma.name,
        asc:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN 2 WHEN ? IS NOT NULL THEN 1 ELSE 0 END",
            aps.exclusive_to_group_member_id,
            aps.exclusive_to_group_id
          ),
        asc_nulls_last: aps.priority
      ]
    )
  end

  ## Events — model CRUD ---------------------------------------------------

  @impl true
  # Paso 0 del alta: en vez de abrir el form directo, se abre el selector de
  # TIPO. El tipo decide todo lo que sigue — el filtrado del catálogo, los
  # proveedores que aparecen en el paso de credenciales (capability) y el
  # `model_type` con el que el row se guarda — así que se elige primero y el
  # form ya no lo vuelve a preguntar.
  def handle_event("new_model", _params, socket) do
    if socket.assigns.is_admin do
      {:noreply,
       socket
       # Las credenciales se releen aquí: una API key creada en la página de
       # proveedores DESPUÉS del mount no está en la lista del mount, y el paso
       # 2 se quedaría sin ella (y sin key no hay listado).
       |> assign_form_data()
       |> assign(:form, nil)
       |> assign(:editing_model_id, nil)
       |> assign(:model_form_picked_type, nil)
       |> assign(:type_picker_open, true)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  # Elegido el tipo: se abre el form de creación con ese tipo prellenado. Los
  # tres servicios de media rutean por su endpoint propio (capability =
  # model_type), así que el tipo elegido ES el valor de la columna.
  #
  # El vocabulario que este handler acepta es EXACTAMENTE el que el picker
  # ofrece — los tipos con ruta pública (`type_endpoint/1`, el mismo filtro de
  # `model_type_choices/0`). Una lista copiada a mano se desincroniza.
  def handle_event("pick_model_type", %{"type" => type}, socket) when is_binary(type) do
    cond do
      not socket.assigns.is_admin ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      type_endpoint(type) == nil ->
        {:noreply, socket}

      true ->
        {:noreply, start_new_model(socket, type)}
    end
  end

  def handle_event("pick_model_type", _params, socket), do: {:noreply, socket}

  # Volver del form al selector de tipo (paso 0): nada del form sobrevive.
  def handle_event("back_to_type_picker", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_model_id, nil)
     |> assign(:model_form_picked_type, nil)
     # The listing state belongs to the wizard session that is being abandoned:
     # leaving it behind showed its error/spinner on the next alta.
     |> assign(:wizard_models, [])
     |> assign(:wizard_models_error, nil)
     |> assign(:wizard_models_loading, false)
     |> assign(:type_picker_open, true)}
  end

  ## Events — wizard (proveedor → modelo → datos) -----------------------------

  # Paso 1 → elegido el proveedor, se acota TODO a él: su semilla curada para
  # el tipo y sus API keys. Y si tiene UNA sola key, se preselecciona: con una
  # sola no hay nada que elegir, y continuar sin key dejaba el paso 3 vacío sin
  # que el operador supiera por qué (misma regla que el modal de lane:
  # `default_credential_id/1`).
  def handle_event("wizard_pick_provider", %{"key" => key}, socket) do
    if socket.assigns.is_admin do
      type = socket.assigns[:model_form_picked_type]
      credentials = wizard_credentials_for(socket, key)
      credential_id = default_credential_id(credentials)

      {:noreply,
       socket
       |> assign(:wizard_provider_key, key)
       |> assign(:wizard_provider_label, provider_label_for(socket, key))
       |> assign(:wizard_models, wizard_seed_models(key, type))
       |> assign(:wizard_credentials, credentials)
       |> assign(:wizard_credential_id, credential_id)
       # El label sale de la LISTA, no del socket: en un pipe `socket` es el de
       # antes de estos assigns, así que leerlo aquí devolvía nil y el chip decía
       # "no key" con la key ya elegida.
       |> assign(:wizard_credential_label, credential_label_for(credentials, credential_id))
       |> assign(:wizard_provider_model, nil)
       |> assign(:wizard_step, "credential")}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  # Paso 2 (servicios): el id elegido de la lista curada pasa a ser el
  # `provider_model` del lane y, como nombre del modelo, su forma corta — que
  # sigue siendo editable en el paso 3.
  def handle_event("wizard_pick_model", %{"model" => model}, socket)
      when is_binary(model) do
    if socket.assigns.is_admin and socket.assigns.form do
      # `source.data` es el struct VACÍO: lo que el operador ya eligió (el TIPO,
      # sobre todo) vive en `source.changes`. Se arrastra entero para no perderlo
      # al rearmar el changeset con el nombre del id elegido.
      params =
        socket.assigns.form.source.changes
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("name", ModelIds.short_name(model))

      changeset = Providers.change_model(socket.assigns.form.source.data, params)

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model))
       |> assign(:wizard_provider_model, model)
       |> assign(:wizard_step, "details")}
    else
      {:noreply, socket}
    end
  end

  # Salto al paso 3 sin elegir del catálogo: es el camino del modelo que nadie
  # publica (se escribe el nombre y el id a mano).
  def handle_event("wizard_skip_model", _params, socket) do
    {:noreply,
     socket
     |> assign(:wizard_step, "details")
     |> assign_form_picked_type()}
  end

  # Any step of the wizard is a valid target: the template moves back to
  # `provider` / `credential`, and the details step's "Change" lands on
  # `credential`. A step outside the wizard is a no-op instead of a crash.
  def handle_event("wizard_back", %{"step" => step}, socket)
      when step in ~w(provider credential model) do
    {:noreply, assign(socket, :wizard_step, step)}
  end

  def handle_event("wizard_back", _params, socket), do: {:noreply, socket}

  # Clicking a step crumb jumps to that step (tab-style navigation).
  def handle_event("goto_wizard_step", %{"step" => step}, socket)
      when step in ~w(provider credential model details) do
    {:noreply, assign(socket, :wizard_step, step)}
  end

  def handle_event("goto_wizard_step", _params, socket), do: {:noreply, socket}

  def handle_event("wizard_search_providers", params, socket) do
    {:noreply, assign(socket, :wizard_provider_search, query_param(params))}
  end

  def handle_event("wizard_pick_credential", %{"credential_id" => id}, socket)
      when is_binary(id) do
    credential_id = if id == "", do: nil, else: id

    {:noreply,
     socket
     |> assign(:wizard_credential_id, credential_id)
     |> assign(:wizard_credential_label, wizard_credential_label_for(socket, credential_id))
     |> fetch_wizard_models(credential_id)}
  end

  # Del paso 2 al 3: se entra al listado Y se pide. Pedirlo sólo al CAMBIAR la
  # key dejaba el paso 3 vacío cuando la key llegaba ya elegida (un proveedor
  # con una sola key, o una vuelta atrás desde otro paso).
  def handle_event("wizard_continue", %{"step" => "model"}, socket) do
    {:noreply,
     socket
     |> fetch_wizard_models(socket.assigns[:wizard_credential_id])
     |> assign(:wizard_step, "model")}
  end

  def handle_event("wizard_continue", %{"step" => "credential"}, socket) do
    {:noreply, assign(socket, :wizard_step, "credential")}
  end

  def handle_event("wizard_continue", _params, socket), do: {:noreply, socket}

  def handle_event("wizard_pick_credential", _params, socket), do: {:noreply, socket}

  # El input del id del modelo en el proveedor: su propio `name` es la clave del
  # payload (el select no está dentro del form del modelo, así que no hay
  # anidamiento que desenvolver).
  def handle_event("wizard_pick_provider_model", %{"wizard_provider_model" => value}, socket)
      when is_binary(value) do
    {:noreply, assign(socket, :wizard_provider_model, value)}
  end

  def handle_event("wizard_pick_provider_model", _params, socket), do: {:noreply, socket}

  # Elegir lab o icono reescribe el changeset del formulario abierto (nada se
  # guarda hasta el submit): la vista previa y el propio campo reflejan la
  # elección al instante. El vínculo con el catálogo viaja en un hidden, así que
  # revalidar con los params del formulario no lo pierde.
  def handle_event("validate_model", %{"model" => model_params}, socket) do
    if socket.assigns.is_admin and socket.assigns.form do
      changeset = Providers.change_model(socket.assigns.form.source.data, model_params)

      {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_model_icon", %{"icon" => icon}, socket) when is_binary(icon) do
    if socket.assigns.is_admin and socket.assigns.form do
      changeset = Ecto.Changeset.put_change(socket.assigns.form.source, :icon, icon)

      {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_model_id, nil)
     |> assign(:model_form_picked_type, nil)
     |> assign(:type_picker_open, false)
     |> reset_wizard()}
  end

  def handle_event("toggle_pin", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      case fetch_model(model_id) do
        nil ->
          {:noreply, socket}

        model ->
          new_pinned = !model.pinned

          case Providers.update_model(model, %{pinned: new_pinned}) do
            {:ok, _updated} ->
              audit(socket, "model.pin_toggle", "model", model.id, %{
                "name" => model.name,
                "pinned" => new_pinned
              })

              {:noreply, load_models(socket)}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, gettext("Could not update the model."))}
          end
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("toggle_pin", _params, socket), do: {:noreply, socket}

  def handle_event("edit_guard_rails", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      case fetch_model(model_id) do
        nil ->
          {:noreply, socket}

        model ->
          changeset = Providers.change_model(model)

          {:noreply,
           socket
           |> assign(:guard_rails_form, to_form(changeset, as: :model))
           |> assign(:guard_rails_model_id, model.id)}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("edit_guard_rails", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_guard_rails", _params, socket) do
    {:noreply,
     socket
     |> assign(:guard_rails_form, nil)
     |> assign(:guard_rails_model_id, nil)}
  end

  def handle_event("save_guard_rails", %{"model" => model_params}, socket) do
    cond do
      # L38 — `cancel_guard_rails` limpia el id; un submit encolado detrás de
      # Cancelar llega con nil y no puede reventar en get_model!/1.
      is_nil(socket.assigns.guard_rails_model_id) ->
        {:noreply, socket}

      not socket.assigns.is_admin ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      true ->
        case fetch_model(socket.assigns.guard_rails_model_id) do
          nil ->
            {:noreply, socket}

          model ->
            case Providers.update_model(model, model_params) do
              {:ok, _updated} ->
                audit(socket, "model.guard_rails_update", "model", model.id, %{
                  "name" => model.name,
                  "changes" =>
                    Map.take(model_params, [
                      "guard_rails",
                      "prompt_cache_enabled",
                      "lazy_cleanup_enabled"
                    ])
                })

                {:noreply,
                 socket
                 |> put_flash(:info, gettext("Guard rails updated."))
                 |> assign(:guard_rails_form, nil)
                 |> assign(:guard_rails_model_id, nil)
                 |> load_models()}

              {:error, changeset} ->
                {:noreply, assign(socket, :guard_rails_form, to_form(changeset, as: :model))}
            end
        end
    end
  end

  # Editing opens the SAME modal as creating, picker included: an existing model
  # can be linked or re-linked to the catalog from here. The results start empty
  # (the create modal shows the first page as a browse list, which is noise above
  # an already-configured row): typing brings them up.
  def handle_event("edit_model", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      case fetch_model(model_id) do
        # Id forjado o borrado entre el render y el click: no-op.
        nil ->
          {:noreply, socket}

        model ->
          changeset = Providers.change_model(model)
          type = model.model_type || "llm"

          {:noreply,
           socket
           |> assign_form_data()
           |> assign(:form, to_form(changeset, as: :model))
           |> assign(:editing_model_id, model.id)
           # La edición entra al mismo wizard que el alta: el tipo del row queda
           # fijado desde el primer paso, así los proveedores se acotan al tipo
           # real del modelo en vez de mostrar todos.
           |> assign(:model_form_picked_type, type)
           # La edición entra directo a los DATOS: el tipo del row ya está
           # decidido. Y trae la relación REAL del modelo — sus lanes (API key +
           # el id que viaja al upstream), no un "proveedor" que el modelo no
           # tiene: el proveedor es una propiedad de la key.
           |> assign(:wizard_lanes, model_lanes(model.id))
           |> assign(:wizard_step, "details")}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("edit_model", _params, socket), do: {:noreply, socket}

  # "Change" sobre un lane DENTRO del modal de edición del modelo: los lanes
  # viven ahora en la página del modelo, así que el clic navega ahí con el modal
  # del lane ya abierto (`?edit=<id>`).
  def handle_event("edit_model_provider_from_modal", %{"id" => ap_id}, socket) do
    case fetch_lane(ap_id) do
      nil ->
        {:noreply, socket}

      ap ->
        {:noreply, push_navigate(socket, to: ~p"/catalog/models/#{ap.model_id}?edit=#{ap.id}")}
    end
  end

  def handle_event("edit_model_provider_from_modal", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_model", %{"model" => model_params}, socket) do
    if socket.assigns.is_admin do
      save_model(socket, socket.assigns.editing_model_id, model_params)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("delete_model", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      case delete_model_locked(model_id) do
        {:ok, model} ->
          audit(socket, "model.delete", "model", model.id, %{"name" => model.name})

          {:noreply,
           socket
           |> put_flash(:info, gettext("Model deleted."))
           |> load_models()}

        {:error, :has_providers} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Cannot delete: the model has providers assigned. Remove them first.")
           )}

        # Id forjado o modelo inexistente: no-op.
        {:error, :not_found} ->
          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete the model."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("delete_model", _params, socket), do: {:noreply, socket}

  # Check-then-delete bajo lock: el `FOR UPDATE` sobre la fila del modelo
  # serializa dos borrados (y cualquier alta de lane que tome el mismo modelo),
  # así que la comprobación de lanes y el DELETE ven el MISMO estado. Sin el
  # lock, dos submits simultáneos podían pasar los dos el `Repo.exists?` y uno
  # borraba con lanes recién asignadas.
  defp delete_model_locked(model_id) do
    case fetch_model(model_id) do
      nil ->
        {:error, :not_found}

      model ->
        Repo.transaction(fn ->
          case Repo.one(from(m in Model, where: m.id == ^model.id, lock: "FOR UPDATE")) do
            nil ->
              Repo.rollback(:not_found)

            %Model{} = locked ->
              if Repo.exists?(from(ap in ModelProvider, where: ap.model_id == ^locked.id)) do
                Repo.rollback(:has_providers)
              else
                case Providers.delete_model(locked) do
                  {:ok, deleted} -> deleted
                  {:error, reason} -> Repo.rollback({:delete_failed, reason})
                end
              end
          end
        end)
        |> case do
          {:ok, deleted} -> {:ok, deleted}
          {:error, :not_found} -> {:error, :not_found}
          {:error, :has_providers} -> {:error, :has_providers}
          {:error, {:delete_failed, _reason}} -> {:error, :delete_failed}
        end
    end
  end

  ## Private helpers — wizard ----------------------------------------------

  # Abre el form de alta con el tipo ya elegido: el paso 0 sólo decide el tipo,
  # el wizard arranca en el paso del proveedor. Las asignaciones de un alta
  # anterior se reinician aquí para que ninguna sobreviva al selector de tipo.
  defp start_new_model(socket, type) do
    changeset = Providers.change_model(%Model{}, %{"model_type" => type})

    socket
    |> assign(:model_form_picked_type, type)
    |> assign(:type_picker_open, false)
    |> assign(:form, to_form(changeset, as: :model))
    |> assign(:editing_model_id, :new)
    # Paso 1 del wizard: el proveedor. Se elige DESPUÉS del tipo y ANTES del
    # modelo, porque es el tipo el que decide qué proveedores pueden servir
    # el modelo y el proveedor el que decide qué modelos se ofrecen.
    |> assign(:wizard_step, "provider")
    |> assign(:wizard_provider_key, nil)
    |> assign(:wizard_provider_model, nil)
    |> assign(:wizard_credential_id, nil)
    |> assign(:wizard_credential_label, nil)
    |> assign(:wizard_models, [])
    # A fresh alta starts with no listing state: the error and the spinner
    # of the previous one must not survive the type picker.
    |> assign(:wizard_models_error, nil)
    |> assign(:wizard_models_loading, false)
    |> load_wizard_providers(type)
  end

  # El changeset del form guarda el TIPO elegido en `changes` (el `data` del
  # struct está vacío). Rearmarlo con él garantiza que el tipo no se pierda al
  # pasar por los pasos del wizard: sin esto, el modelo guardado nacía `llm`
  # aunque el operador hubiera elegido «imagen» en el paso 0.
  defp assign_form_picked_type(socket) do
    case socket.assigns[:form] do
      nil ->
        socket

      form ->
        changeset =
          Ecto.Changeset.put_change(
            form.source,
            :model_type,
            socket.assigns[:model_form_picked_type] || "llm"
          )

        assign(socket, :form, to_form(changeset, as: :model))
    end
  end

  defp load_wizard_providers(socket, type) do
    providers =
      if is_binary(type) do
        # Sólo los proveedores ACTIVOS que DECLARAN el tipo: un Fireworks no
        # sirve imagen, y ofrecerlo en el paso 1 es un callejón sin salida.
        Providers.providers_declaring(type)
      else
        []
      end

    socket
    |> assign(:wizard_providers, providers)
    |> assign(:wizard_provider_search, "")
    |> assign(:wizard_credentials, [])
  end

  @doc """
  Los proveedores del paso 1 que casan con el texto buscado (nombre o key).

  Sin texto devuelve todos: la lista ya viene acotada por el tipo del modelo, y
  filtrar en memoria sobre un puñado de filas es lo que hace instantáneo el
  buscador.
  """
  def wizard_provider_results(providers, search) do
    needle = search |> to_string() |> String.trim() |> String.downcase()

    if needle == "" do
      List.wrap(providers)
    else
      Enum.filter(List.wrap(providers), fn provider ->
        String.contains?(String.downcase(provider.name || ""), needle) or
          String.contains?(String.downcase(provider.key || ""), needle)
      end)
    end
  end

  @doc """
  Los ids que un proveedor publica para un tipo, según la semilla curada EN
  CÓDIGO (`ServiceModels.known_ids/2`): el suelo del paso 3 cuando el proveedor
  no publica catálogo por servicio (DashScope para los tres servicios de media)
  o cuando todavía no hay key con la que listarlo.
  """
  def wizard_seed_models(provider_key, type) do
    ServiceModels.known_ids(provider_key, type)
  end

  @doc """
  La referencia con la que la UI identifica un proveedor: su `key` (el vínculo
  con el catálogo) o, para un custom que no tiene, su `id`.
  """
  def credential_label(credential) do
    name = credential.name || gettext("Key")

    case credential.api_key_encrypted do
      key when is_binary(key) -> "#{name} (#{mask_key(key)})"
      _ -> name
    end
  end

  # Los lanes de un modelo con su credencial (y el proveedor de ésta): es la
  # relación que el modelo SÍ tiene. Incluye los deshabilitados a propósito —
  # "existe pero no sirve" es información, no ruido.
  defp model_lanes(model_id) when is_binary(model_id) do
    from(mp in Tokengate.Providers.ModelProvider,
      where: mp.model_id == ^model_id,
      order_by: [asc_nulls_last: mp.priority, asc: mp.credential_id],
      preload: [credential: :provider, pool: [members: [credential: :provider]]]
    )
    |> Repo.all()
  end

  defp model_lanes(_), do: []

  # Label de una credencial DENTRO de una lista ya cargada (puro, sin socket:
  # ver el pitfall del pipe en `wizard_pick_provider`).
  defp credential_label_for(_credentials, nil), do: nil

  defp credential_label_for(credentials, credential_id) do
    case Enum.find(credentials || [], &(&1.id == credential_id)) do
      nil -> nil
      credential -> credential_label(credential)
    end
  end

  defp wizard_credential_label_for(_socket, nil), do: nil

  defp wizard_credential_label_for(socket, credential_id) do
    case Enum.find(socket.assigns[:wizard_credentials] || [], &(&1.id == credential_id)) do
      nil -> nil
      credential -> credential_label(credential)
    end
  end

  defp wizard_credentials_for(socket, provider_ref) do
    (socket.assigns[:credentials_for_select] || [])
    |> Enum.filter(fn credential ->
      # key para un builtin (que es como se referencia en el catálogo), id para
      # un custom, que no tiene key.
      credential.provider.key == provider_ref or credential.provider.id == provider_ref
    end)
  end

  defp provider_label_for(socket, ref) do
    case Enum.find(List.wrap(socket.assigns[:wizard_providers]), fn provider ->
           provider_ref(provider) == ref
         end) do
      %{name: name} when is_binary(name) -> name
      _ -> ref
    end
  end

  # El listado del paso 3 se pide al elegir la API key: es una llamada HTTP y
  # bloquear el `handle_event` del modal dejaría la UI congelada, así que el
  # resultado llega por mensaje y se descarta si el operador ya cambió de
  # proveedor, de tipo o de key.
  defp fetch_wizard_models(socket, credential_id) do
    provider_key = socket.assigns[:wizard_provider_key]
    type = socket.assigns[:model_form_picked_type]

    credential =
      Enum.find(socket.assigns[:wizard_credentials] || [], &(&1.id == credential_id))

    if credential && is_binary(type) do
      provider = credential.provider
      lv_pid = self()

      Task.start(fn ->
        result =
          try do
            list_provider_models(provider, credential, type)
          rescue
            # Un adapter que raise (credencial indescifrable, Finch sin
            # clasificar) no puede dejar el spinner colgado: el mensaje de error
            # limpia el estado como cualquier {:error, _}.
            e -> {:error, Exception.message(e)}
          end

        send(lv_pid, {:wizard_models_result, provider_key, type, credential_id, result})
      end)

      socket
      |> assign(:wizard_models_loading, true)
      |> assign(:wizard_models_error, nil)
    else
      # Sin credencial no hay petición: el estado de la anterior no puede
      # sobrevivir (ni el error ni el spinner) — sería el de otra sesión.
      socket
      |> assign(:wizard_models_loading, false)
      |> assign(:wizard_models_error, nil)
    end
  end

  # El listado en vivo GANA (es el catálogo autoritativo del proveedor); la
  # semilla se une para que un id que el endpoint no liste (una variante recién
  # publicada, un alias) siga estando a mano. Si el listado falló, se queda la
  # semilla: mejor un selector corto que uno vacío.
  defp merge_wizard_models(seed, {:ok, live}) do
    (seed ++ live) |> Enum.uniq() |> Enum.sort()
  end

  defp merge_wizard_models(seed, _error), do: seed

  # El motivo del fallo se muestra tal cual (un átomo del vocabulario de
  # `ProviderAdapter.classify_error/1` o el mensaje de una excepción): un
  # "no publica nada" cuando la verdad es "no me contestó" es peor que no decir
  # nada, porque manda al operador a escribir a mano un id que sí existía.
  defp wizard_models_error({:ok, _ids}), do: nil
  defp wizard_models_error({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp wizard_models_error({:error, reason}), do: to_string(reason)

  ## Private helpers — model save ------------------------------------------

  # El wizard crea el modelo Y su primer lane de una vez: el operador ya eligió
  # proveedor (y por tanto la credencial) antes de llegar a los datos del
  # modelo. Sin proveedor elegido — o sin ninguna API key suya — el modelo se
  # crea igual y el lane se añade después desde la fila (el modal de siempre).
  #
  # La unidad de precio del lane nace con la del TIPO del modelo, para que el
  # operador no tenga que acordarse de cambiarla.
  #
  # Devuelve `:ok` o `{:error, reason}`: el llamador necesita saber POR QUÉ no
  # hubo lane para poder decirlo — antes el `:error` se descartaba y el flash
  # anunciaba una alta completa.
  defp create_wizard_lane(socket, model) do
    credential_id = socket.assigns[:wizard_credential_id]
    provider_model = socket.assigns[:wizard_provider_model]

    cond do
      not is_binary(credential_id) ->
        {:error, :no_credential}

      not is_binary(provider_model) or String.trim(provider_model) == "" ->
        {:error, :no_provider_model}

      true ->
        unit = Pricing.default_unit_for_type(model.model_type || "llm")

        attrs =
          %{
            model_id: model.id,
            credential_id: credential_id,
            provider_model: provider_model,
            priority: 1,
            enabled: true,
            pricing_unit: unit
          }

        case Providers.create_model_provider(attrs) do
          {:ok, ap} ->
            audit(socket, "model_provider.create", "model_provider", ap.id, %{
              "model_id" => model.id,
              "provider_model" => provider_model,
              "via" => "wizard"
            })

            :ok

          {:error, _changeset} ->
            {:error, :invalid_lane}
        end
    end
  end

  # El wizard se resetea al cerrar/salvar: el siguiente alta empieza en el paso 1
  # sin arrastrar el proveedor del anterior.
  defp reset_wizard(socket) do
    socket
    |> assign(:wizard_step, "provider")
    |> assign(:wizard_providers, [])
    |> assign(:wizard_provider_search, "")
    |> assign(:wizard_provider_key, nil)
    |> assign(:wizard_provider_label, nil)
    |> assign(:wizard_provider_model, nil)
    |> assign(:wizard_credentials, [])
    |> assign(:wizard_credential_id, nil)
    |> assign(:wizard_credential_label, nil)
    |> assign(:wizard_models, [])
    |> assign(:wizard_models_loading, false)
    |> assign(:wizard_models_error, nil)
    |> assign(:wizard_lanes, [])
  end

  defp save_model(socket, :new, model_params) do
    case Providers.create_model(model_params) do
      {:ok, model} ->
        audit(socket, "model.create", "model", model.id, %{"name" => model.name})

        {:noreply,
         put_lane_result_flash(socket, create_wizard_lane(socket, model))
         |> assign(:form, nil)
         |> assign(:editing_model_id, nil)
         |> reset_wizard()
         |> load_models()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
    end
  end

  # L38 — ver save_model_provider/3: un submit con id stale no debe tirar el
  # LiveView con un FunctionClauseError.
  defp save_model(socket, nil, _model_params), do: {:noreply, socket}

  defp save_model(socket, model_id, model_params) when is_binary(model_id) do
    case fetch_model(model_id) do
      nil ->
        {:noreply, socket}

      model_record ->
        case Providers.update_model(model_record, model_params) do
          {:ok, updated} ->
            audit(socket, "model.update", "model", updated.id, %{
              "name" => updated.name,
              "changes" =>
                Map.take(model_params, [
                  "name",
                  "context_window",
                  "model_type",
                  "lab_key",
                  "icon"
                ])
            })

            {:noreply,
             socket
             |> put_flash(:info, gettext("Model updated."))
             |> assign(:form, nil)
             |> assign(:editing_model_id, nil)
             |> load_models()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
        end
    end
  end

  ## Private helpers — model_provider save ---------------------------------

  # El resultado del lane decide el flash: un alta que eligió proveedor prometió
  # una asignación, así que su fallo es un error que dice el motivo — nunca un
  # "Model created." que deje creer que el modelo ya se sirve.
  defp put_lane_result_flash(socket, :ok),
    do: put_flash(socket, :info, gettext("Model created with its first provider assignment."))

  # "Create by hand" no prometió lane: ahí el modelo solo es el resultado
  # esperado (el modal de edición es donde se añade la key).
  defp put_lane_result_flash(socket, {:error, reason}) do
    if is_nil(socket.assigns[:wizard_provider_key]) do
      put_flash(socket, :info, gettext("Model created."))
    else
      put_flash(socket, :error, lane_error_message(reason))
    end
  end

  defp lane_error_message(:no_credential),
    do:
      gettext(
        "Model created without a provider assignment: no API key was selected for this provider."
      )

  defp lane_error_message(:no_provider_model),
    do: gettext("Model created without a provider assignment: the provider model id is empty.")

  defp lane_error_message(_reason),
    do: gettext("Model created without a provider assignment: the assignment could not be saved.")

  @impl true
  def handle_info(
        {:wizard_models_result, provider_key, type, credential_id, result},
        %{assigns: assigns} = socket
      ) do
    if assigns[:wizard_provider_key] == provider_key and
         assigns[:model_form_picked_type] == type and
         assigns[:wizard_credential_id] == credential_id do
      {:noreply,
       socket
       |> assign(:wizard_models_loading, false)
       |> assign(:wizard_models_error, wizard_models_error(result))
       |> assign(
         :wizard_models,
         merge_wizard_models(assigns[:wizard_models] || [], result)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  # La marca: logo remoto si es el del lab, si no un hero icon. El chip claro es
  # fijo porque los logos del catálogo son oscuros y el tema también lo es
  # (mismo criterio que las cards de labs/proveedores).
  attr :mark, :any, required: true
  attr :id, :string, required: true
  attr :size, :string, default: "sm"

  defp mark_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "flex items-center justify-center shrink-0 rounded-lg border border-base-300 bg-white overflow-hidden",
        if(@size == "md", do: "w-10 h-10", else: "w-8 h-8")
      ]}
    >
      <img
        :if={elem(@mark, 0) == :logo}
        src={elem(@mark, 1)}
        alt=""
        class={if(@size == "md", do: "w-7 h-7", else: "w-5 h-5")}
        loading="lazy"
      />
      <.icon
        :if={elem(@mark, 0) == :icon}
        name={elem(@mark, 1)}
        class={["text-neutral-600", if(@size == "md", do: "w-6 h-6", else: "w-4 h-4")]}
      />
    </span>
    """
  end

  # El formulario abierto manda sobre la fila guardada: lo que se elige se ve en
  # la vista previa antes de guardar.
  #
  # Los blanks llegan como `""` (el valor del form sale de los params crudos,
  # no del changeset normalizado), y `""` es truthy: sin este filtro la vista
  # previa le pasaría `name: ""` a `<.icon>` y el render crashearía la vista
  # entera — el modal «se reinicia» al primer teclado en la pestaña custom.
  defp preview_model(form) do
    %Model{
      lab_key: blank_to_nil(form[:lab_key].value),
      icon: blank_to_nil(form[:icon].value)
    }
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(value == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  defp linked_lab(form, labs_by_key) do
    Map.get(labs_by_key || %{}, form[:lab_key].value)
  end

  # Un `lab_key` que no está en la tabla (el vínculo es blando) se ofrece igual:
  # si no, el select no podría representarlo y guardar lo borraría en silencio.
  defp lab_options(form, lab_choices) do
    key = form[:lab_key].value
    choices = lab_choices || []

    if is_binary(key) and key != "" and not Enum.any?(choices, fn {_label, k} -> k == key end) do
      choices ++ [{"#{key} (lab desconocido)", key}]
    else
      choices
    end
  end

  defp mark_origin(form, labs_by_key) do
    case linked_lab(form, labs_by_key) do
      %Lab{} = lab ->
        gettext("Lab badge: %{lab}.", lab: lab.name)

      nil ->
        case form[:icon].value do
          icon when is_binary(icon) and icon != "" -> gettext("The model's own icon.")
          _ -> gettext("Generic icon: link a lab or pick one from the palette.")
        end
    end
  end

  def empty_state_message, do: gettext("No models configured.")

  ## Contadores de la tabla -------------------------------------------------

  @doc "Cuántas API keys (lanes) sirven a este modelo."
  def lane_count(%{model_providers: lanes}), do: length(lanes || [])
  def lane_count(_model), do: 0

  @doc "Cuántos proveedores distintos sirven a este modelo."
  def lane_provider_count(%{model_providers: lanes}) do
    lanes
    |> List.wrap()
    |> Enum.map(&lane_provider_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  def lane_provider_count(_model), do: 0

  @doc "Cantidad de keys de un lane de pool (0 cuando el lane es de una key)."
  def lane_pool_member_count(%{pool: %{members: members}}) when is_list(members),
    do: length(members)

  def lane_pool_member_count(_lane), do: 0

  # Un lane de pool no tiene `credential_id`: su proveedor es el del pool, y sin
  # esto todos los lanes de pool colapsaban en un mismo `nil` (el conteo los
  # contaba como UNO y escondía el resto).
  defp lane_provider_key(%{pool: %{provider_id: provider_id}}) when is_binary(provider_id),
    do: provider_id

  defp lane_provider_key(lane), do: Map.get(lane, :credential_id)

  @doc """
  El precio más barato de las lanes del modelo, como `{unidad, monto}`.

  `:mixed` cuando las lanes cobran en unidades distintas — no hay nada que
  comparar y un número inventado sería peor que decirlo. `nil` cuando ninguna
  lane tiene precio capturado.
  """
  def price_summary(%{model_providers: lanes}) do
    priced =
      lanes
      |> List.wrap()
      |> Enum.map(fn lane ->
        unit = lane.pricing_unit || Pricing.default_unit()

        amount =
          if Pricing.token_unit?(unit),
            do: Map.get(lane, :input_cost_per_million),
            else: Map.get(lane, :unit_cost)

        {unit, amount}
      end)
      |> Enum.reject(fn {_unit, amount} -> is_nil(amount) end)

    case priced do
      [] ->
        nil

      [{unit, amount}] ->
        {unit, amount}

      [{unit, _} | _] = all ->
        if Enum.all?(all, fn {u, _} -> u == unit end) do
          {unit, all |> Enum.map(&elem(&1, 1)) |> Enum.min_by(&Decimal.to_float/1)}
        else
          :mixed
        end
    end
  end

  def price_summary(_model), do: nil

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
          {gettext("Models")}
          <:subtitle>{gettext("Configure models and the API keys that serve them")}</:subtitle>
          <:actions :if={@is_admin}>
            <.button phx-click="new_model" id="new-model-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New model")}
            </.button>
          </:actions>
        </.header>

        <%!-- Una fila por modelo. Las API keys que lo sirven viven en su propia
             página (/catalog/models/:id): aquí sólo se cuentan. El estado vacío
             lo pinta `.table` (`:empty`): con stream no puede inferirlo, así que
             llega en `empty?`. La etiqueta de sección viaja en la primera celda
             del modelo que abre el grupo (`@model_sections`). --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm overflow-x-auto">
          <.table
            id="models"
            rows={@streams.models}
            row_item={fn {_id, model} -> model end}
            row_class="align-top"
            empty?={@models_empty?}
          >
            <:col :let={model} label={gettext("Model")}>
              <div
                :if={section = Map.get(@model_sections, model.id)}
                id={"model-section-#{section.type}"}
                class="flex items-center gap-1.5 mb-1.5"
              >
                <.icon name={section.icon} class="w-3.5 h-3.5 text-base-content/40" />
                <span class="text-[11px] font-semibold uppercase tracking-wider text-base-content/40">
                  {section.label}
                </span>
                <span class="badge badge-xs badge-ghost">{section.count}</span>
              </div>
              <div class="flex items-center gap-2">
                <.mark_badge
                  mark={Model.mark(model, @labs_by_key)}
                  id={"model-mark-#{model.id}"}
                />
                <div class="min-w-0">
                  <.link
                    navigate={~p"/catalog/models/#{model.id}"}
                    class="font-medium link link-hover truncate block"
                    id={"model-link-#{model.id}"}
                  >
                    {model.name}
                  </.link>
                  <span class="text-[11px] text-base-content/40">
                    {format_compact(model.context_window)} ctx
                  </span>
                </div>
                <span
                  :if={model.pinned}
                  class="text-warning shrink-0"
                  id={"model-pinned-#{model.id}"}
                  title={gettext("Pinned")}
                >
                  <.icon name="hero-star-solid" class="w-3 h-3" />
                </span>
              </div>
            </:col>
            <:col :let={model} label={gettext("Type")}>
              <div class="flex flex-col gap-0.5">
                <span
                  id={"model-badge-#{model.id}"}
                  class="badge badge-sm badge-outline badge-info w-fit"
                >
                  {model.model_type}
                </span>
                <span
                  :if={endpoint = type_endpoint(model.model_type)}
                  id={"model-endpoint-#{model.id}"}
                  class="font-mono text-[10px] text-base-content/40 whitespace-nowrap"
                  title={gettext("Endpoint that serves this model type")}
                >
                  {endpoint}
                </span>
              </div>
            </:col>
            <:col
              :let={model}
              label={gettext("Keys")}
              align="right"
              tooltip={gettext("Manage the API keys that serve this model")}
            >
              <.link
                navigate={~p"/catalog/models/#{model.id}"}
                class="link link-hover whitespace-nowrap inline-flex items-center gap-1"
                id={"model-keys-#{model.id}"}
                title={gettext("Manage the API keys that serve this model")}
              >
                <.icon name="hero-key" class="w-3 h-3" /> {lane_count(model)}
              </.link>
            </:col>
            <:col :let={model} label={gettext("Providers")} align="right">
              <span class="badge badge-ghost badge-sm">{lane_provider_count(model)}</span>
            </:col>
            <:col :let={model} label={gettext("Price")} align="right">
              <%= case price_summary(model) do %>
                <% nil -> %>
                  <span class="text-base-content/30">—</span>
                <% :mixed -> %>
                  <span class="text-[11px] text-base-content/40">
                    {gettext("mixed units")}
                  </span>
                <% {unit, amount} -> %>
                  <span class="text-sm whitespace-nowrap" title={Pricing.label(unit)}>
                    ${fmt_price(amount)}
                    <span class="text-[10px] text-base-content/40">
                      /{Pricing.rate_suffix(unit)}
                    </span>
                  </span>
              <% end %>
            </:col>
            <:action :let={model} :if={@is_admin}>
              <button
                phx-click="toggle_pin"
                phx-value-id={model.id}
                class="btn btn-xs btn-ghost"
                id={"pin-model-#{model.id}"}
                title={if model.pinned, do: gettext("Unpin"), else: gettext("Pin to top")}
                aria-label={if model.pinned, do: gettext("Unpin"), else: gettext("Pin to top")}
              >
                <.icon
                  name={if model.pinned, do: "hero-star-solid", else: "hero-star"}
                  class={["w-3.5 h-3.5", model.pinned && "text-warning"]}
                />
              </button>
              <button
                phx-click="edit_guard_rails"
                phx-value-id={model.id}
                class="btn btn-xs btn-ghost"
                id={"guard-rails-#{model.id}"}
                title={gettext("Guard Rails")}
                aria-label={gettext("Guard Rails")}
              >
                <.icon name="hero-shield-check" class="w-3.5 h-3.5" />
              </button>
              <button
                phx-click="edit_model"
                phx-value-id={model.id}
                class="btn btn-xs btn-ghost"
                id={"edit-model-#{model.id}"}
                title={gettext("Edit")}
                aria-label={gettext("Edit")}
              >
                <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
              </button>
              <button
                phx-click="delete_model"
                phx-value-id={model.id}
                data-confirm={gettext("Delete this model? This action cannot be undone.")}
                class="btn btn-xs btn-ghost text-error"
                id={"delete-model-#{model.id}"}
                title={gettext("Delete")}
                aria-label={gettext("Delete")}
              >
                <.icon name="hero-trash" class="w-3.5 h-3.5" />
              </button>
            </:action>
            <:empty>
              <.icon name="hero-cpu-chip" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{empty_state_message()}</p>
            </:empty>
          </.table>
        </div>

        <%!-- Paso 0: selector de tipo. Un modelo nuevo se elige AQUÍ, no en el
             form — el tipo acota catálogo y proveedores antes de que exista
             nada que llenar. Sólo en creación; la edición cambia el tipo desde
             el select del form. --%>
        <div
          :if={@type_picker_open}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id="model-type-picker"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-1">{gettext("New model")}</h2>
              <p class="text-sm text-base-content/60 mb-4">
                {gettext(
                  "First choose the type — it decides which providers are offered and the endpoint that will serve the model."
                )}
              </p>
              <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
                <button
                  :for={{label, type, icon} <- model_type_choices()}
                  type="button"
                  phx-click="pick_model_type"
                  phx-value-type={type}
                  id={"pick-type-#{type}"}
                  class="btn btn-outline btn-sm flex flex-col h-auto py-3 gap-1 normal-case"
                >
                  <.icon name={icon} class="w-5 h-5" />
                  <span class="text-xs">{label}</span>
                </button>
              </div>
              <div class="card-actions justify-end mt-2">
                <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Alta/edición en el contenedor único (`.modal`): el componente pinta
             el título, el indicador de pasos (`.steps`) y cierra con ✕/Escape/
             click-away por `cancel_form`. El wizard es el mismo de siempre — 4
             pasos: proveedor (acotado por el tipo) → API key → modelo → datos —
             y el paso vive en `@wizard_step`: el modal no cambia, sólo lo que
             renderiza dentro. En edición no hay pasos (todo está ya decidido),
             así que `steps` va nil y el indicador no aparece. --%>
        <.modal
          :if={@form}
          id="model-wizard"
          title={if @editing_model_id == :new, do: gettext("New model"), else: gettext("Edit model")}
          on_close="cancel_form"
          max_w="max-w-4xl"
          steps={if @editing_model_id == :new, do: wizard_steps(), else: nil}
          current_step={@wizard_step}
          step_click="goto_wizard_step"
        >
          <div class="min-h-0">
            <%= if @wizard_step == "provider" do %>
              <p class="text-sm text-base-content/60 mb-3">
                {gettext(
                  "Choose the provider that will serve this model. Only the providers that can serve the type you picked are listed."
                )}
              </p>

              <form
                id="wizard-provider-search-form"
                phx-change="wizard_search_providers"
                phx-submit="wizard_search_providers"
              >
                <input
                  type="text"
                  name="q"
                  id="wizard-provider-search"
                  value={@wizard_provider_search}
                  placeholder={gettext("Search provider… (e.g. openrouter, alibaba)")}
                  class="input input-sm w-full mb-2"
                  autocomplete="off"
                  phx-debounce="150"
                />
              </form>

              <div
                :if={wizard_provider_results(@wizard_providers, @wizard_provider_search) == []}
                id="wizard-provider-empty"
                class="text-sm text-base-content/50 py-4 text-center"
              >
                {gettext("No provider declares this type.")}
                {gettext("You can still create the model by hand and assign a provider later.")}
              </div>

              <div
                :if={wizard_provider_results(@wizard_providers, @wizard_provider_search) != []}
                id="wizard-provider-results"
                class="max-h-72 overflow-y-auto rounded-lg border border-base-300"
              >
                <button
                  :for={p <- wizard_provider_results(@wizard_providers, @wizard_provider_search)}
                  type="button"
                  phx-click="wizard_pick_provider"
                  phx-value-key={provider_ref(p)}
                  id={"wizard-provider-#{dom_key(provider_ref(p))}"}
                  class="w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/60 last:border-0 flex items-center gap-2"
                >
                  <img
                    :if={p.logo_url}
                    src={p.logo_url}
                    alt=""
                    data-logo
                    class="w-5 h-5 shrink-0 rounded"
                    loading="lazy"
                  />
                  <%!-- El icono va SIEMPRE (oculto si hay logo): una URL que
                     no carga no dispara el fallback del servidor, así que la
                     revela el listener global de `error` en app.js. --%>
                  <.icon
                    name="hero-server-stack"
                    class={["w-5 h-5 shrink-0 text-base-content/30", p.logo_url && "hidden"]}
                  />
                  <span class="flex-1 min-w-0">
                    <span class="text-sm font-medium truncate">{p.name}</span>
                    <span class="text-xs text-base-content/50 font-mono ml-1">{p.key}</span>
                  </span>
                  <span
                    :if={length(p.credentials) > 0}
                    class="badge badge-xs badge-success shrink-0"
                    title={gettext("It already has API keys")}
                  >
                    {length(p.credentials)} key(s)
                  </span>
                  <span
                    :if={length(p.credentials) == 0}
                    class="badge badge-xs badge-ghost shrink-0"
                  >
                    {gettext("no key")}
                  </span>
                </button>
              </div>

              <div class="flex justify-between mt-3">
                <button
                  type="button"
                  phx-click="back_to_type_picker"
                  class="btn btn-ghost btn-sm"
                  id="wizard-back-to-type"
                >
                  {gettext("Back")}
                </button>
                <div class="flex gap-2">
                  <button
                    type="button"
                    phx-click="wizard_skip_model"
                    class="btn btn-outline btn-sm"
                    id="wizard-custom"
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Create by hand")}
                  </button>
                </div>
              </div>
            <% end %>

            <%= if @wizard_step in ~w(credential model) and @wizard_provider_key do %>
              <div
                class="flex items-center gap-2 px-3 py-2 mb-3 rounded-lg bg-primary/10 border border-primary/30"
                id="wizard-chosen-provider"
              >
                <.icon name="hero-server-stack" class="w-4 h-4 text-primary shrink-0" />
                <span class="text-sm font-medium flex-1">{@wizard_provider_label}</span>
                <button
                  type="button"
                  phx-click="wizard_back"
                  phx-value-step="provider"
                  class="btn btn-xs btn-ghost"
                  id="wizard-change-provider"
                >
                  <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Change")}
                </button>
              </div>

              <%!-- Paso 2: la API key. No es una formalidad — es lo que permite
                     preguntarle al proveedor qué modelos sirve para este tipo. --%>
              <%= if @wizard_step == "credential" do %>
                <div class="rounded-lg border border-base-300 p-3 mb-4" id="wizard-key-step">
                  <div class="fieldset mb-2">
                    <label class="label" for="wizard-credential">
                      {gettext("Credential (API key)")}
                    </label>
                    <%!-- phx-submit: sin él, Enter en el select resuelve en un
                           submit NATIVO (recarga /catalog/models) y tira el
                           wizard entero. --%>
                    <form
                      id="wizard-credential-form"
                      phx-change="wizard_pick_credential"
                      phx-submit="wizard_pick_credential"
                    >
                      <select
                        id="wizard-credential"
                        name="credential_id"
                        class="select select-sm w-full"
                      >
                        <option value="">{gettext("Pick an API key from this provider")}</option>
                        <option
                          :for={c <- @wizard_credentials}
                          value={c.id}
                          selected={@wizard_credential_id == c.id}
                        >
                          {credential_label(c)}
                        </option>
                      </select>
                    </form>
                  </div>

                  <p
                    :if={@wizard_credentials == []}
                    class="text-xs text-warning mt-1"
                    id="wizard-no-credentials"
                  >
                    {gettext(
                      "This provider has no API keys yet: the model is created without a provider assignment. Add the key on the Providers page and assign it afterwards."
                    )}
                  </p>

                  <p :if={@wizard_credentials != []} class="text-xs text-base-content/50 mt-1">
                    {gettext(
                      "With this key the gateway asks the provider which models it serves for this type."
                    )}
                  </p>
                </div>

                <div class="flex justify-between mt-3">
                  <button
                    type="button"
                    phx-click="wizard_back"
                    phx-value-step="provider"
                    class="btn btn-ghost btn-sm"
                    id="wizard-back-to-provider"
                  >
                    {gettext("Back")}
                  </button>
                  <button
                    type="button"
                    phx-click="wizard_continue"
                    phx-value-step="model"
                    class="btn btn-primary btn-sm"
                    id="wizard-continue"
                  >
                    {gettext("See its models")}
                  </button>
                </div>
              <% end %>

              <%!-- Paso 3: los modelos que publica ESE proveedor para ESE tipo,
                     en vivo con la key. Donde el proveedor no publica catálogo
                     (DashScope para los tres servicios de media) queda la semilla curada
                     en código. --%>
              <%= if @wizard_step == "model" do %>
                <div
                  class="flex items-center gap-2 mb-3 text-xs text-base-content/70"
                  id="wizard-models-key"
                >
                  <.icon name="hero-key" class="w-3.5 h-3.5 text-primary shrink-0" />
                  <span class="font-mono flex-1">
                    {@wizard_credential_label || gettext("no key")}
                  </span>
                  <button
                    type="button"
                    phx-click="wizard_back"
                    phx-value-step="credential"
                    class="btn btn-xs btn-ghost"
                    id="wizard-change-key-from-models"
                  >
                    <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Change")}
                  </button>
                </div>

                <div id="wizard-models" class="mb-4">
                  <p class="text-xs text-base-content/60 mb-2 flex items-center gap-2">
                    <span>
                      {gettext("Models this provider serves for this type:")}
                      <b id="wizard-models-count">{length(@wizard_models)}</b>
                    </span>
                    <span
                      :if={@wizard_models_loading}
                      class="flex items-center gap-1 text-base-content/50"
                      id="wizard-models-loading"
                    >
                      <span class="loading loading-spinner loading-xs"></span>
                      {gettext("asking the provider…")}
                    </span>
                  </p>

                  <div
                    :if={@wizard_models != []}
                    class="max-h-56 overflow-y-auto rounded-lg border border-base-300"
                  >
                    <button
                      :for={m <- @wizard_models}
                      type="button"
                      phx-click="wizard_pick_model"
                      phx-value-model={m}
                      id={"wizard-model-#{dom_key(m)}"}
                      class="block w-full text-left px-3 py-2 text-sm font-mono hover:bg-primary/10 transition-colors border-b border-base-300/60 last:border-0"
                    >
                      {m}
                    </button>
                  </div>

                  <%!-- Tres estados distintos, TRES mensajes: "no hay key"
                         (no se preguntó), "no contestó" (se preguntó y falló) y
                         "no publica" (contestó y no trae nada de este tipo). El
                         primero manda al operador al paso 2; el segundo le dice
                         POR QUÉ; el tercero es el único que invita a teclear. --%>
                  <p
                    :if={is_nil(@wizard_credential_id) and @wizard_models == []}
                    class="text-sm text-base-content/60 py-3"
                    id="wizard-models-need-key"
                  >
                    {gettext(
                      "Pick an API key in the previous step: the list comes from the provider itself."
                    )}
                  </p>

                  <p
                    :if={@wizard_models_error}
                    class="text-sm text-error py-3"
                    id="wizard-models-error"
                  >
                    {gettext("The provider did not answer the listing:")}
                    <span class="font-mono">{@wizard_models_error}</span>
                  </p>

                  <p
                    :if={
                      @wizard_models == [] and !@wizard_models_loading and
                        @wizard_models_error == nil and @wizard_credential_id
                    }
                    class="text-sm text-base-content/50 py-3"
                    id="wizard-models-empty"
                  >
                    {gettext(
                      "This provider does not publish a list for this type: write the id by hand in the next step."
                    )}
                  </p>
                </div>

                <div class="flex justify-between mt-3">
                  <button
                    type="button"
                    phx-click="wizard_back"
                    phx-value-step="credential"
                    class="btn btn-ghost btn-sm"
                    id="wizard-back-to-credential"
                  >
                    {gettext("Back")}
                  </button>
                  <button
                    type="button"
                    phx-click="wizard_skip_model"
                    class="btn btn-outline btn-sm"
                    id="wizard-write-by-hand"
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Write it by hand")}
                  </button>
                </div>
              <% end %>
            <% end %>

            <%!-- La relación que el modelo SÍ tiene: sus lanes, cada uno con su
                   API key (y el proveedor de esa key) y el id que viaja al
                   upstream. Es de donde se lee —y se cambia— cómo se sirve el
                   modelo; el "proveedor" no es una relación suya. --%>
            <%= if @editing_model_id not in [nil, :new] do %>
              <div class="rounded-lg border border-base-300 p-3 mb-4" id="model-serving-lanes">
                <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-2">
                  {gettext("Served by (API keys)")}
                </h4>

                <p
                  :if={@wizard_lanes == []}
                  class="text-sm text-base-content/40 py-1"
                  id="model-lanes-empty"
                >
                  {gettext(
                    "No API key assigned yet: the model is registered but nothing can route to it."
                  )}
                </p>

                <div
                  :for={lane <- @wizard_lanes}
                  id={"model-lane-#{lane.id}"}
                  class="flex items-center gap-2 py-1.5 border-b border-base-200 last:border-0"
                >
                  <span class="flex-1 min-w-0 truncate text-sm">
                    <%!-- La key, y nada más: el modelo se relaciona con ELLA. El
                           proveedor que la posee no se pinta aquí — vive en su
                           página, y se elige al crear la key. Un lane de pool no
                           tiene key: se identifica por el pool y su conteo. --%>
                    <%= cond do %>
                      <% lane.pool -> %>
                        <span class="font-mono text-xs" id={"lane-pool-name-#{lane.id}"}>
                          {lane.pool.name}
                        </span>
                        <span
                          class="badge badge-xs badge-info ml-1"
                          id={"lane-pool-badge-#{lane.id}"}
                          title={gettext("API keys in this pool: rotation per request")}
                        >
                          {lane_pool_member_count(lane)} key(s)
                        </span>
                      <% lane.credential -> %>
                        <span class="font-mono text-xs">
                          {lane.credential.name || gettext("unnamed key")}
                        </span>
                        <span class="text-xs text-base-content/40 ml-1">
                          {mask_key(lane.credential.api_key_encrypted)}
                        </span>
                      <% true -> %>
                        {gettext("no credential")}
                    <% end %>
                    <span :if={!lane.enabled} class="badge badge-xs badge-ghost ml-1">
                      {gettext("disabled")}
                    </span>
                  </span>
                  <span class="font-mono text-xs text-base-content/60 truncate max-w-[14rem]">
                    {lane.provider_model}
                  </span>
                  <%= if @is_admin do %>
                    <button
                      type="button"
                      phx-click="edit_model_provider_from_modal"
                      phx-value-id={lane.id}
                      class="btn btn-xs btn-ghost"
                      id={"model-lane-change-#{lane.id}"}
                    >
                      <.icon name="hero-pencil" class="w-3 h-3" /> {gettext("Change")}
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Paso 4: los datos del modelo y lo que el wizard ya decidió —
                   la API key que lo sirve y el id que viaja al upstream. La key
                   viene PRIMERO: es la relación del modelo. El proveedor no se
                   repite aquí — el dueño de la key, no un vínculo del modelo. --%>
            <%= if @wizard_step == "details" do %>
              <%= if @wizard_provider_key do %>
                <div class="rounded-lg border border-base-300 p-3 mb-4" id="wizard-lane">
                  <div
                    class="flex items-center gap-2 mb-3"
                    id="wizard-chosen-key"
                  >
                    <.icon name="hero-key" class="w-4 h-4 text-primary shrink-0" />
                    <span class="text-sm font-mono font-medium flex-1">
                      {@wizard_credential_label || gettext("no key")}
                    </span>
                    <button
                      type="button"
                      phx-click="wizard_back"
                      phx-value-step="credential"
                      class="btn btn-xs btn-ghost"
                      id="wizard-change-key"
                    >
                      <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Change")}
                    </button>
                  </div>

                  <div class="fieldset mb-2">
                    <label class="label" for="wizard-provider-model">
                      {gettext("Model id at the provider")}
                    </label>
                    <%!-- phx-submit: Enter en el id resuelve en un submit NATIVO
                           sin él (recarga y se pierde el wizard). --%>
                    <form
                      id="wizard-provider-model-form"
                      phx-change="wizard_pick_provider_model"
                      phx-submit="wizard_pick_provider_model"
                    >
                      <input
                        type="text"
                        id="wizard-provider-model"
                        name="wizard_provider_model"
                        value={@wizard_provider_model || ""}
                        class="input input-sm w-full"
                        phx-debounce="300"
                      />
                    </form>
                  </div>

                  <p
                    :if={@wizard_credentials == []}
                    class="text-xs text-warning mt-1"
                    id="wizard-no-credentials"
                  >
                    {gettext(
                      "This provider has no API keys yet: the model is created without a provider assignment. Add the key on the Providers page and assign it afterwards."
                    )}
                  </p>
                </div>
              <% end %>

              <.form for={@form} id="model-form" phx-change="validate_model" phx-submit="save_model">
                <div class="grid md:grid-cols-2 gap-x-8 gap-y-1">
                  <div>
                    <.input
                      field={@form[:name]}
                      type="text"
                      label={gettext("Name (identifier)")}
                      required
                      hint={gettext("This is what clients send in `model`. It must be unique.")}
                    />
                    <.input
                      field={@form[:model_type]}
                      type="select"
                      label={gettext("Model type")}
                      options={
                        model_type_choices()
                        |> Enum.map(fn {label, type, _icon} -> {label, type} end)
                      }
                      hint={
                        gettext("Defines which endpoint serves it (chat, embeddings, audio, image).")
                      }
                    />
                    <.input
                      field={@form[:context_window]}
                      type="number"
                      label={gettext("Context window (tokens)")}
                      required
                      hint={gettext("Maximum context size of the model in tokens.")}
                    />
                  </div>

                  <div class="space-y-1">
                    <div class="divider my-2 text-xs text-base-content/50">
                      {gettext("Brand (lab / icon)")}
                    </div>
                    <%!--
                      La marca sale del lab vinculado cuando lo hay; sin lab, del
                      icono propio del modelo, elegible de una paleta. Misma
                      precedencia que un lab (`Model.mark/2`), resuelta contra el
                      índice de labs cargado una vez.
                    --%>
                    <.input
                      field={@form[:lab_key]}
                      type="select"
                      label={gettext("Lab (who built the model)")}
                      options={lab_options(@form, @lab_choices)}
                      prompt={gettext("— No lab —")}
                      hint={
                        gettext(
                          "With a linked lab its brand wins; without one the icon below is used."
                        )
                      }
                    />

                    <div class="fieldset mb-2">
                      <span class="label">{gettext("Preview")}</span>
                      <div
                        class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-200/40 px-3 h-16"
                        id="model-mark-preview"
                      >
                        <.mark_badge
                          mark={Model.mark(preview_model(@form), @labs_by_key)}
                          id="model-mark-preview-inner"
                          size="md"
                        />
                        <span class="text-xs text-base-content/60" id="model-mark-origin">
                          {mark_origin(@form, @labs_by_key)}
                        </span>
                      </div>
                    </div>

                    <%= if linked_lab(@form, @labs_by_key) do %>
                      <p class="text-xs text-base-content/50">
                        {gettext("The model's own icon is queued: it is used if you unlink the lab.")}
                      </p>
                    <% else %>
                      <details
                        class="group rounded-lg border border-base-300 mt-2"
                        id="model-icon-section"
                      >
                        <summary class="flex items-center justify-between cursor-pointer select-none px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content list-none [&::-webkit-details-marker]:hidden">
                          <span class="flex items-center gap-2">
                            <.icon name="hero-swatch" class="w-4 h-4" />
                            {gettext("Icon palette")}
                          </span>
                          <.icon
                            name="hero-chevron-down"
                            class="w-4 h-4 transition-transform group-open:rotate-180"
                          />
                        </summary>
                        <div class="px-3 pb-3 pt-1 space-y-2">
                          <.input
                            field={@form[:icon]}
                            type="text"
                            label={gettext("Icon")}
                            placeholder={Model.default_icon()}
                            hint={gettext("Hero icon name, e.g. hero-fire. Optional.")}
                          />

                          <div class="fieldset">
                            <span class="label">{gettext("Pick from the palette")}</span>
                            <div class="grid grid-cols-8 gap-1" id="model-icon-picker">
                              <button
                                :for={icon <- @icon_choices}
                                type="button"
                                phx-click="pick_model_icon"
                                phx-value-icon={icon}
                                class={[
                                  "flex items-center justify-center rounded-lg border p-1.5 transition-colors",
                                  if(@form[:icon].value == icon,
                                    do: "border-primary bg-primary/10 text-primary",
                                    else: "border-base-300 hover:bg-base-200"
                                  )
                                ]}
                                id={"model-icon-choice-#{icon}"}
                                title={icon}
                              >
                                <.icon name={icon} class="w-4 h-4" />
                              </button>
                            </div>
                          </div>
                        </div>
                      </details>
                    <% end %>
                  </div>
                </div>

                <%!-- Behavior: effort policy, tuned after creation. Collapsed
                     by default so the identity fields stay above the fold. --%>
                <details
                  class="group rounded-lg border border-base-300 mt-4"
                  id="model-reasoning-section"
                >
                  <summary class="flex items-center justify-between cursor-pointer select-none px-3 py-2 text-sm font-medium text-base-content/70 hover:text-base-content list-none [&::-webkit-details-marker]:hidden">
                    <span class="flex items-center gap-2">
                      <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
                      {gettext("Reasoning effort (advanced)")}
                    </span>
                    <.icon
                      name="hero-chevron-down"
                      class="w-4 h-4 transition-transform group-open:rotate-180"
                    />
                  </summary>
                  <div class="px-3 pb-3 pt-1 grid md:grid-cols-2 gap-x-8 gap-y-1">
                    <.input
                      field={@form[:effort_default]}
                      type="select"
                      label={gettext("Reasoning effort default")}
                      options={effort_policy_options()}
                      prompt={gettext("— No default —")}
                      hint={
                        gettext(
                          "Replaces a client reasoning_effort of none/minimal with this value (upstreams that reject those values)."
                        )
                      }
                    />

                    <.input
                      field={@form[:effort_override]}
                      type="select"
                      label={gettext("Reasoning effort override")}
                      options={effort_policy_options()}
                      prompt={gettext("— No override —")}
                      hint={
                        gettext(
                          "Replaces the client reasoning_effort with this value, whatever the client sends."
                        )
                      }
                    />
                  </div>
                </details>

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-model-btn">
                    {gettext("Save")}
                  </button>
                </div>
              </.form>
            <% end %>
          </div>
        </.modal>

        <%!-- Guard Rails form --%>
        <div :if={@guard_rails_form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_guard_rails" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-2">
                Guard Rails
              </h2>
              <p class="text-sm text-base-content/60 mb-4">
                {gettext("Text injected at the start of every system prompt sent to the provider.")}
                {gettext("Use it for behaviour instructions, content limits, or formatting rules.")}
              </p>

              <.form for={@guard_rails_form} id="guard-rails-form" phx-submit="save_guard_rails">
                <.input
                  field={@guard_rails_form[:guard_rails]}
                  type="textarea"
                  label={gettext("System instructions (guard rails)")}
                  rows="8"
                  placeholder={
                    gettext("E.g. Always answer in English. Do not use markdown. Be concise…")
                  }
                  hint={
                    gettext(
                      "This text is prepended to the user system prompt. Leave it empty to inject nothing."
                    )
                  }
                />

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_guard_rails" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-guard-rails-btn">
                    {gettext("Save")}
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
