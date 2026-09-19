defmodule TokengateWeb.ModelsLive do
  @moduledoc """
  CRUD for models + per-model model_provider management.

  Admins can create, edit, and delete models, and assign providers to each
  model (provider_model, priority, enabled toggle, scope).
  Managers and regular users see a read-only list.

  Models are global. Admins can create, edit, and delete models,
  and assign providers to each model.

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
  alias Tokengate.Accounts
  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Lab,
    Model,
    ModelCatalog,
    ModelProvider,
    Pricing,
    Provider,
    ServiceModels
  }

  alias Tokengate.Proxy.ProviderAdapter
  alias Tokengate.Repo

  # The picker hands at most this many catalog rows to the modal: the list is
  # filtered in memory on every keystroke, and no operator scrolls past the first
  # handful of matches.
  @catalog_results_limit 40
  @provider_results_limit 8

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
      |> assign(:catalog_models, nil)
      |> assign(:catalog_query, "")
      |> assign(:catalog_results, [])
      |> assign(:catalog_type_count, 0)
      |> assign(:catalog_picker_providers, [])
      |> assign(:catalog_provider_filter, nil)
      |> assign(:catalog_keys_taken, MapSet.new())
      |> assign(:lab_logos, %{})
      |> assign(:labs_by_key, %{})
      |> assign(:lab_choices, [])
      |> assign(:icon_choices, @icon_choices)
      |> assign(:model_form_tab, "catalog")
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
      |> assign(:wizard_media_models, [])
      |> assign(:wizard_provider_model, nil)
      |> assign(:wizard_credential_id, nil)
      |> assign(:wizard_credentials, [])
      |> assign(:wizard_media_models_loading, false)
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
      |> load_scope_data()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_models(socket) do
    models = aliases_with_providers_query() |> Repo.all()

    socket
    |> stream(:models, models, reset: true)
    |> assign(:models_empty?, models == [])
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

  @doc """
  The model_type of the model the provider form is working on — it decides
  which upstream catalogue to list (embeddings vs chat models). Unknown or
  absent ids fall back to "llm".
  """
  def model_type_for(model_id) when is_binary(model_id) do
    case Providers.get_model(model_id) do
      nil -> "llm"
      model_ -> model_.model_type || "llm"
    end
  end

  def model_type_for(_model_id), do: "llm"

  @doc """
  Las unidades de precio que TIENEN sentido para el modelo del form, como
  `{label, key}` para el select: un modelo de imagen se cobra por imagen o por
  megapíxel, uno de voz por mil caracteres, y así — no por tokens.

  La unidad vive en el LANE (`model_providers.pricing_unit`), no en el modelo,
  porque dos proveedores del mismo modelo pueden cobrar distinto.
  """
  def pricing_unit_options(model_id) do
    model_id
    |> model_type_for()
    |> Pricing.options_for_type()
    |> Enum.map(&{&1.label, &1.key})
  end

  @doc """
  True cuando la unidad elegida se cobra por tokens — es lo que decide si el
  form muestra los tres campos `*_cost_per_million` o el `unit_cost`.
  """
  def token_priced?(unit), do: Pricing.token_unit?(unit)

  @doc """
  The 8 model types offered at creation, in picker order: `{label, type,
  hero-icon}`. The type IS the routing capability — it decides which endpoint
  serves the model — so the labels name the endpoint's job, not the modality.
  """
  def model_type_choices do
    [
      {gettext("LLM (chat)"), "llm", "hero-chat-bubble-left-right"},
      {gettext("Embedding"), "embedding", "hero-squares-2x2"},
      {gettext("Decisions"), "decision", "hero-scale"},
      {gettext("Rerank"), "rerank", "hero-arrow-up-circle"},
      {gettext("Transcription"), "stt", "hero-microphone"},
      {gettext("Speech"), "tts", "hero-speaker-wave"},
      {gettext("Images"), "image", "hero-photo"},
      {gettext("Videos"), "video", "hero-film"},
      {gettext("Music"), "music", "hero-musical-note"}
    ]
  end

  # Providers are grouped by scope first — global, then group-exclusive,
  # then member-exclusive — and ordered by priority within each group.
  defp aliases_with_providers_query do
    from(ma in Model,
      left_join: aps in assoc(ma, :model_providers),
      preload: [model_providers: {aps, [credential: :provider]}],
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

  defp assign_form_data(socket) do
    credentials =
      from(c in Tokengate.Providers.Credential,
        where: c.status == "active",
        preload: [:provider]
      )
      |> Repo.all()
      |> Enum.sort_by(fn credential ->
        {String.downcase(credential.provider.name), String.downcase(credential.name || "")}
      end)

    socket
    |> assign(:credentials_for_select, credentials)
  end

  defp load_scope_data(socket) do
    groups = Accounts.list_groups()

    members =
      from(tm in Tokengate.Accounts.GroupMember,
        preload: [:user],
        order_by: [asc: tm.id]
      )
      |> Repo.all()

    socket
    |> assign(:groups_for_select, groups)
    |> assign(:members_for_select, members)
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
       |> ensure_catalog_models()
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
  # seis servicios de media rutean por su endpoint propio (capability =
  # model_type), así que el tipo elegido ES el valor de la columna.
  @service_types ~w(decision rerank stt tts image video music)

  def handle_event("pick_model_type", %{"type" => type}, socket)
      when type in ["llm", "embedding" | @service_types] do
    if socket.assigns.is_admin do
      changeset =
        Providers.change_model(%Model{}, %{"model_type" => type})

      socket =
        socket
        |> assign(:model_form_picked_type, type)
        |> assign(:type_picker_open, false)
        |> assign(:form, to_form(changeset, as: :model))
        |> assign(:editing_model_id, :new)
        |> assign(:model_form_tab, "catalog")
        |> assign(:catalog_picker_providers, Providers.catalog_picker_providers(type))
        |> assign(:catalog_provider_filter, nil)
        |> filter_catalog_models("")
        # Paso 1 del wizard: el proveedor. Se elige DESPUÉS del tipo y ANTES del
        # modelo, porque es el tipo el que decide qué proveedores pueden servir
        # el modelo y el proveedor el que decide qué modelos se ofrecen.
        |> assign(:wizard_step, "provider")
        |> assign(:wizard_provider_key, nil)
        |> assign(:wizard_provider_model, nil)
        |> assign(:wizard_credential_id, nil)
        |> assign(:wizard_media_models, [])
        |> load_wizard_providers(type)

      {:noreply, socket}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
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
     |> assign(:type_picker_open, true)}
  end

  ## Events — wizard (proveedor → modelo → datos) -----------------------------

  # Paso 1 → elegido el proveedor, se acota TODO a él: el catálogo (qué modelos
  # sirve) y la lista curada de servicios (qué ids de ese servicio publica). Es
  # lo que hace que el paso 2 no sea una lista de 3000 filas con la mitad
  # irrelevantes.
  def handle_event("wizard_pick_provider", %{"key" => key}, socket) do
    if socket.assigns.is_admin do
      type = socket.assigns[:model_form_picked_type]

      {:noreply,
       socket
       |> assign(:wizard_provider_key, key)
       |> assign(:wizard_provider_label, provider_label_for(socket, key))
       |> assign(:catalog_provider_filter, key)
       |> assign(:wizard_media_models, media_models_for(key, type))
       |> assign(:wizard_credentials, wizard_credentials_for(socket, key))
       |> assign(:wizard_credential_id, nil)
       |> assign(:wizard_provider_model, nil)
       |> filter_catalog_models("")
       |> fetch_wizard_service_models(key, type)
       |> assign(:wizard_step, "model")}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  # Paso 2 (servicios): el id elegido de la lista curada pasa a ser el
  # `provider_model` del lane y, como nombre del modelo, su forma corta — que
  # sigue siendo editable en el paso 3.
  def handle_event("wizard_pick_media_model", %{"model" => model}, socket)
      when is_binary(model) do
    if socket.assigns.is_admin and socket.assigns.form do
      # `source.data` es el struct VACÍO: lo que el operador ya eligió (el TIPO,
      # sobre todo) vive en `source.changes`. Se arrastra entero para no perderlo
      # al rearmar el changeset con el nombre del id elegido.
      params =
        socket.assigns.form.source.changes
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("name", ModelCatalog.short_name(model))

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

  # Salto del paso 1 al 2 sin proveedor: el operador quiere ver el catálogo
  # entero (o el modelo no está en el catálogo de un proveedor concreto). No
  # crea lane, así que el modelo queda sin proveedor asignado — igual que el
  # camino de "crear a mano".
  def handle_event("wizard_skip_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:wizard_step, "model")
     |> assign(:catalog_provider_filter, nil)
     |> assign(:wizard_media_models, [])
     |> assign(:wizard_media_models_loading, false)
     |> filter_catalog_models("")}
  end

  def handle_event("wizard_back", %{"step" => step}, socket)
      when step in ~w(provider model) do
    {:noreply, assign(socket, :wizard_step, step)}
  end

  def handle_event("wizard_search_providers", params, socket) do
    {:noreply, assign(socket, :wizard_provider_search, query_param(params))}
  end

  def handle_event("wizard_pick_credential", %{"credential_id" => id}, socket)
      when is_binary(id) do
    {:noreply, assign(socket, :wizard_credential_id, if(id == "", do: nil, else: id))}
  end

  def handle_event("wizard_pick_credential", _params, socket), do: {:noreply, socket}

  # El input del id del modelo en el proveedor: su propio `name` es la clave del
  # payload (el select no está dentro del form del modelo, así que no hay
  # anidamiento que desenvolver).
  def handle_event("wizard_pick_provider_model", %{"wizard_provider_model" => value}, socket)
      when is_binary(value) do
    {:noreply, assign(socket, :wizard_provider_model, value)}
  end

  def handle_event("wizard_pick_provider_model", _params, socket), do: {:noreply, socket}

  ## Events — model catalog picker -------------------------------------------

  # The picker is the default tab when CREATING: a catalog entry fills the form
  # with models.dev metadata. "Personalizado" is the same form with nothing
  # prefilled, which is how a model nobody publishes gets built.
  def handle_event("set_model_tab", %{"tab" => tab}, socket) when tab in ~w(catalog custom) do
    {:noreply, assign(socket, :model_form_tab, tab)}
  end

  # Search over name, models.dev id and lab. In memory: the mirror is ~3000 rows,
  # so every keystroke is instant and costs no query (same trade-off as the
  # provider picker).
  def handle_event("search_catalog_models", params, socket) do
    {:noreply, filter_catalog_models(socket, query_param(params))}
  end

  # Picking a catalog row PRE-FILLS the form the operator already has open: name
  # (the id without its lab prefix), context window, model type
  # and the link back to the catalog entry. Nothing is locked — every field stays
  # editable and nothing is written until the form is submitted.
  #
  # It applies over the form's own data, so the SAME event links a new model and
  # RE-links an existing one (`source.data` is the row being edited there, not a
  # blank struct): re-filling must never drop the row's identity and turn an
  # update into a second insert.
  def handle_event("pick_catalog_model", %{"key" => key}, socket) do
    if socket.assigns.is_admin and socket.assigns.form do
      case Enum.find(socket.assigns.catalog_models || [], &(&1.key == key)) do
        nil ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("That model is not in the catalog. Reload the page.")
           )}

        entry ->
          params = ModelCatalog.to_model_params(entry)

          # Un modelo de servicio o decisión (stt, tts, decision…) elegido en
          # el paso 0 conserva SU tipo: el hint del catálogo solo conoce
          # llm/embedding/decision por prefijo y pisaría el tipo elegido. El
          # tipo elegido gana; name/context/lab/link se rellenan igual.
          params =
            case socket.assigns[:model_form_picked_type] do
              type when type in ["llm", "embedding", nil] -> params
              picked -> %{params | model_type: picked}
            end

          changeset =
            Providers.change_model(
              socket.assigns.form.source.data,
              params
            )

          # Con un proveedor ya elegido (wizard), el `provider_model` del lane
          # sale de SU oferta para este modelo, y el wizard avanza a los datos:
          # el operador ya eligió proveedor y modelo, no hay nada más que
          # escoger antes de guardar.
          {socket, step} =
            case socket.assigns[:wizard_provider_key] do
              nil ->
                {socket, socket.assigns[:wizard_step]}

              provider_key ->
                provider_model =
                  case Providers.offer_for(key, provider_key) do
                    %{provider_model: pm} when is_binary(pm) -> pm
                    _ -> key
                  end

                {assign(socket, :wizard_provider_model, provider_model), "details"}
            end

          {:noreply,
           socket
           |> assign(:form, to_form(changeset, as: :model))
           # The list collapses: the form is filled, and typing in the search box
           # brings the results straight back.
           |> assign(:catalog_results, [])
           |> assign(:wizard_step, step)}
      end
    else
      {:noreply, socket}
    end
  end

  # Drops the catalog link (and what it prefilled for the model type), so the row
  # is created as a plain custom model.
  def handle_event("clear_catalog_pick", _params, socket) do
    if socket.assigns.is_admin and socket.assigns.form do
      changeset =
        socket.assigns.form.source
        |> Ecto.Changeset.put_change(:catalog_model_key, nil)
        |> Ecto.Changeset.put_change(:lab_key, nil)

      {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
    else
      {:noreply, socket}
    end
  end

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
     |> assign(:model_form_tab, "catalog")
     |> assign(:catalog_query, "")
     |> assign(:catalog_results, [])
     |> assign(:catalog_provider_filter, nil)
     |> assign(:model_form_picked_type, nil)
     |> assign(:type_picker_open, false)
     |> reset_wizard()}
  end

  def handle_event("toggle_pin", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      model = Providers.get_model!(model_id)
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
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("edit_guard_rails", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      model = Providers.get_model!(model_id)
      changeset = Providers.change_model(model)

      {:noreply,
       socket
       |> assign(:guard_rails_form, to_form(changeset, as: :model))
       |> assign(:guard_rails_model_id, model.id)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("cancel_guard_rails", _params, socket) do
    {:noreply,
     socket
     |> assign(:guard_rails_form, nil)
     |> assign(:guard_rails_model_id, nil)}
  end

  def handle_event("save_guard_rails", %{"model" => model_params}, socket) do
    if socket.assigns.is_admin do
      model = Providers.get_model!(socket.assigns.guard_rails_model_id)

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
           |> put_flash(:info, "Guard rails actualizados.")
           |> assign(:guard_rails_form, nil)
           |> assign(:guard_rails_model_id, nil)
           |> load_models()}

        {:error, changeset} ->
          {:noreply, assign(socket, :guard_rails_form, to_form(changeset, as: :model))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  # Editing opens the SAME modal as creating, picker included: an existing model
  # can be linked or re-linked to the catalog from here. The results start empty
  # (the create modal shows the first page as a browse list, which is noise above
  # an already-configured row): typing brings them up.
  def handle_event("edit_model", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      model = Providers.get_model!(model_id)
      changeset = Providers.change_model(model)

      type = model.model_type || "llm"
      socket = ensure_catalog_models(socket)

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model))
       |> assign(:editing_model_id, model.id)
       # La edición entra al mismo wizard que el alta: el tipo del row queda
       # fijado desde el primer paso, así el catálogo y los proveedores se acotan
       # al tipo real del modelo en vez de mostrar todos.
       |> assign(:model_form_picked_type, type)
       |> assign(:catalog_picker_providers, Providers.catalog_picker_providers(type))
       |> assign(:model_form_tab, "catalog")
       # La edición entra directo a los DATOS: el tipo y el proveedor del row ya
       # están decididos, y el paso de modelo sigue disponible para re-vincular
       # el catálogo desde el buscador.
       |> assign(:wizard_step, "details")
       |> assign(:catalog_query, "")
       # La edición NO lista resultados de entrada — sería ruido encima de un row
       # ya configurado, y el buscador los trae al primer tecleo. El contador del
       # tipo sí se calcula, para que el badge diga la verdad.
       |> assign(:catalog_results, [])
       |> assign(:catalog_type_count, catalog_type_count(socket.assigns[:catalog_models], type))}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

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
      model_record = Providers.get_model!(model_id)

      has_providers? =
        Repo.exists?(from(ap in ModelProvider, where: ap.model_id == ^model_id))

      if has_providers? do
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cannot delete: the model has providers assigned. Remove them first.")
         )}
      else
        case Providers.delete_model(model_record) do
          {:ok, _} ->
            audit(socket, "model.delete", "model", model_record.id, %{
              "name" => model_record.name
            })

            {:noreply,
             socket
             |> put_flash(:info, gettext("Model deleted."))
             |> load_models()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete the model."))}
        end
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  ## Events — model_provider management -------------------------------------

  def handle_event("new_model_provider", %{"model_id" => model_id}, socket) do
    if socket.assigns.is_admin do
      # La unidad de precio nace con la del TIPO del modelo: un lane de imagen
      # abre en «por imagen» y uno de voz en «por 1k caracteres», no en tokens.
      # El operador la cambia si su proveedor cobra distinto.
      unit = Pricing.default_unit_for_type(model_type_for(model_id))

      changeset =
        Providers.change_model_provider(%ModelProvider{
          model_id: model_id,
          enabled: true,
          pricing_unit: unit
        })

      {:noreply,
       socket
       |> assign(:provider_form_model_id, model_id)
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, :new)
       |> assign(:current_scope, "global")
       |> assign(:current_scope_group_ids, [])
       |> assign(:current_scope_member_ids, [])
       |> assign(:scope_group_search, "")
       |> assign(:scope_member_search, "")
       |> assign(:scope_group_open, false)
       |> assign(:scope_member_open, false)
       |> assign(:provider_form_provider_key, nil)
       |> assign(:provider_form_credential_id, nil)
       |> assign(:provider_form_is_fireworks, false)
       |> assign(:provider_form_pricing_unit, unit)
       |> assign(:credential_form, nil)
       |> assign(:provider_models, [])
       |> build_provider_choices(model_id)
       |> assign(:provider_credentials, nil)
       |> assign_credential_choices()}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  ## Events — provider + API key ---------------------------------------------

  # Narrows the provider list (name or models.dev key). In memory: the choices
  # are already scoped to the model.
  def handle_event("search_providers", params, socket) do
    {:noreply, filter_provider_choices(socket, query_param(params))}
  end

  # Picking a provider is what makes the rest of the modal concrete: it narrows
  # the credential list to THAT provider's API keys, prefills `provider_model`
  # and the manual price fallback from models.dev, and loads the provider's own
  # catalogue for the suggestion list.
  def handle_event("select_provider", %{"key" => provider_key}, socket) do
    if socket.assigns.is_admin and socket.assigns.provider_form do
      case Enum.find(socket.assigns.provider_choices, &(&1.provider.key == provider_key)) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Unknown provider."))}

        %{provider: provider, offer: offer} ->
          credentials = credentials_of(socket, provider.id)
          credential_id = keep_or_default_credential(socket, credentials)

          changeset =
            socket.assigns.provider_form.source
            |> Ecto.Changeset.put_change(:credential_id, credential_id)

          {:noreply, apply_offer(socket, provider, offer, credentials, changeset, credential_id)}
      end
    else
      {:noreply, socket}
    end
  end

  # A new API key for the selected provider, without leaving the modal: alias +
  # key, the same two fields the providers page asks for. The credential is
  # created in place and left selected, which is what unblocks the model right
  # away.
  def handle_event("new_credential_inline", _params, socket) do
    if socket.assigns.is_admin and selected_provider(socket) do
      changeset = Providers.change_credential(%Tokengate.Providers.Credential{status: "active"})

      {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Pick the provider the API key belongs to first."))}
    end
  end

  def handle_event("cancel_new_credential", _params, socket) do
    {:noreply, assign(socket, :credential_form, nil)}
  end

  # Back to step 1: the provider picker opens again and the credential list goes
  # back to every active key until the next provider is chosen.
  def handle_event("clear_provider_choice", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_form_provider_key, nil)
     |> assign(:provider_credentials, nil)
     |> assign(:credential_form, nil)
     |> filter_provider_choices("")
     |> assign_credential_choices()}
  end

  def handle_event("save_new_credential", %{"credential" => params}, socket) do
    provider = selected_provider(socket)

    cond do
      not socket.assigns.is_admin ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      is_nil(provider) ->
        {:noreply,
         put_flash(socket, :error, gettext("Pick the provider the API key belongs to first."))}

      true ->
        attrs = Map.put(params, "provider_id", provider.id)

        case Providers.create_credential(attrs) do
          {:ok, credential} ->
            audit(socket, "credential.create", "credential", credential.id, %{
              "provider_id" => credential.provider_id,
              "name" => credential.name
            })

            socket =
              socket
              |> assign_form_data()
              |> assign(:credential_form, nil)

            credentials = credentials_of(socket, provider.id)

            changeset =
              socket.assigns.provider_form.source
              |> Ecto.Changeset.put_change(:credential_id, credential.id)

            {:noreply,
             socket
             |> apply_offer(
               provider,
               selected_offer(socket, provider.key),
               credentials,
               changeset,
               credential.id
             )
             |> put_flash(:info, "API key creada y seleccionada.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
        end
    end
  end

  def handle_event("cancel_model_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_form, nil)
     |> assign(:editing_ap_id, nil)
     |> assign(:provider_models, [])
     |> assign(:provider_models_loading, false)
     |> assign(:provider_model_search, "")
     |> assign(:provider_form_credential_id, nil)
     |> assign(:provider_form_is_fireworks, false)
     |> assign(:provider_form_pricing_unit, nil)
     |> assign(:provider_form_provider_key, nil)
     |> assign(:provider_credentials, nil)
     |> assign_credential_choices()
     |> assign(:credential_form, nil)
     |> assign(:provider_choices, [])
     |> assign(:provider_choices_results, [])
     |> assign(:provider_search, "")
     |> assign(:current_scope, "global")
     |> assign(:current_scope_group_ids, [])
     |> assign(:current_scope_member_ids, [])
     |> assign(:scope_group_search, "")
     |> assign(:scope_member_search, "")
     |> assign(:scope_group_open, false)
     |> assign(:scope_member_open, false)}
  end

  def handle_event("edit_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)
      changeset = Providers.change_model_provider(ap)

      scope =
        cond do
          ap.exclusive_to_group_member_id != nil -> "member"
          ap.exclusive_to_group_id != nil -> "group"
          true -> "global"
        end

      # Prefill the search inputs with the current selection's label so the
      # user sees which group / member is bound to the provider.
      group_label =
        if ap.exclusive_to_group_id do
          group =
            Enum.find(
              socket.assigns.groups_for_select || [],
              &(&1.id == ap.exclusive_to_group_id)
            )

          if group, do: group.name, else: ""
        else
          ""
        end

      member_label =
        if ap.exclusive_to_group_member_id do
          member =
            Enum.find(
              socket.assigns.members_for_select || [],
              &(&1.id == ap.exclusive_to_group_member_id)
            )

          if member && member.user, do: member.user.email, else: ""
        else
          ""
        end

      provider_key = provider_key_of_credential(socket, ap.credential_id)

      # Prefill the service_tier checkbox from the stored extra_body (the
      # raw override virtuals are no longer part of the form). The provider is
      # already identified by the row's credential, so models.dev's offer for
      # this model fills the provider_model and the manual prices that are
      # still empty — the operator sees them and can clear them.
      changeset =
        changeset
        |> Ecto.Changeset.put_change(
          :service_tier_priority,
          Map.get(ap.extra_body || %{}, "service_tier") == "priority"
        )
        |> put_offer_defaults(offer_for_provider(ap.model_id, provider_key))

      # The credential list is narrowed to the row's own provider, so editing an
      # assignment shows the keys that can actually serve it.
      provider_credentials =
        case Enum.find(
               socket.assigns[:credentials_for_select] || [],
               &(&1.id == ap.credential_id)
             ) do
          %{provider_id: provider_id} -> credentials_of(socket, provider_id)
          _ -> []
        end

      {:noreply,
       socket
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, ap.id)
       |> assign(:provider_form_model_id, ap.model_id)
       |> assign(:provider_form_credential_id, ap.credential_id)
       |> assign(:provider_form_is_fireworks, credential_is_fireworks?(ap.credential_id, socket))
       |> assign(:provider_form_pricing_unit, ap.pricing_unit || Pricing.default_unit())
       |> assign(:provider_form_provider_key, provider_key)
       |> assign(:provider_credentials, provider_credentials)
       |> assign(:credential_form, nil)
       |> assign(:current_scope, scope)
       |> assign(:current_scope_group_id, ap.exclusive_to_group_id)
       |> assign(:current_scope_member_id, ap.exclusive_to_group_member_id)
       |> assign(:scope_group_search, group_label)
       |> assign(:scope_member_search, member_label)
       |> assign(:provider_models_loading, true)
       |> build_provider_choices(ap.model_id)
       |> assign_credential_choices()
       |> fetch_provider_models(ap.credential_id)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  # Elegir la unidad de precio reescribe el changeset del form abierto (nada se
  # guarda hasta el submit) y conmuta qué campos de precio se muestran: los tres
  # de token, o el `unit_cost`. Es un select con su PROPIO phx-change para no
  # revalidar el form entero en cada tecleo.
  def handle_event(
        "pick_pricing_unit",
        %{"model_provider" => %{"pricing_unit" => unit}},
        socket
      ) do
    form = socket.assigns[:provider_form]

    if socket.assigns.is_admin and form != nil and unit in Pricing.units() do
      changeset = Ecto.Changeset.put_change(form.source, :pricing_unit, unit)

      {:noreply,
       socket
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:provider_form_pricing_unit, unit)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_pricing_unit", _params, socket), do: {:noreply, socket}

  def handle_event("select_provider_model", %{"model" => model}, socket) do
    if socket.assigns.is_admin and socket.assigns.provider_form do
      form =
        to_form(
          Ecto.Changeset.put_change(socket.assigns.provider_form.source, :provider_model, model),
          as: :model_provider
        )

      {:noreply,
       socket
       |> assign(:provider_form, form)
       |> assign(:provider_model_search, model)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_model_provider", %{"model_provider" => ap_params}, socket) do
    if socket.assigns.is_admin do
      # Inject scope fields from assigns into params
      ap_params = inject_scope_params(ap_params, socket.assigns)
      save_model_provider(socket, socket.assigns.editing_ap_id, ap_params)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("provider_form_changed", %{"model_provider" => ap_params}, socket) do
    if socket.assigns.is_admin do
      credential_id = ap_params["credential_id"]
      model_search = ap_params["provider_model"] || ""

      socket =
        socket
        |> assign(:provider_model_search, model_search)

      cond do
        credential_id in [nil, ""] ->
          {:noreply, assign(socket, :provider_models, [])}

        credential_id != socket.assigns[:provider_form_credential_id] ->
          # La API key manda: elegirla DERIVA el proveedor de la fila (y su
          # precio de lista para este modelo). El buscador de proveedores queda
          # como filtro opcional de la lista de keys, no como requisito previo.
          {:noreply,
           socket
           |> apply_credential_provider(credential_id, ap_params)
           |> assign(:provider_models_loading, true)
           |> fetch_provider_models(credential_id)}

        true ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_scope", %{"scope" => scope}, socket) do
    if socket.assigns.is_admin do
      {:noreply,
       socket
       |> assign(:current_scope, scope)
       |> assign(:current_scope_group_ids, [])
       |> assign(:current_scope_member_ids, [])
       |> assign(:scope_group_search, "")
       |> assign(:scope_member_search, "")
       |> assign(:scope_group_open, false)
       |> assign(:scope_member_open, false)}
    else
      {:noreply, socket}
    end
  end

  # Multi-select toggle for create mode — adds/removes a group from the
  # selection list. In edit mode (single existing row) the form uses
  # select_scope_group_item instead.
  def handle_event("toggle_scope_group", %{"group_id" => group_id}, socket) do
    if socket.assigns.is_admin do
      ids = socket.assigns[:current_scope_group_ids] || []

      new_ids =
        if group_id in ids,
          do: List.delete(ids, group_id),
          else: ids ++ [group_id]

      {:noreply, assign(socket, :current_scope_group_ids, new_ids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_scope_member", %{"member_id" => member_id}, socket) do
    if socket.assigns.is_admin do
      ids = socket.assigns[:current_scope_member_ids] || []

      new_ids =
        if member_id in ids,
          do: List.delete(ids, member_id),
          else: ids ++ [member_id]

      {:noreply, assign(socket, :current_scope_member_ids, new_ids)}
    else
      {:noreply, socket}
    end
  end

  # Scope pickers behave as autocomplete combos: open on focus, close on
  # pick / click-away / Escape. The search inputs live inside the provider
  # form; on phx-change LiveView serializes only that input, so the
  # single-select (edit) ones send their value nested as
  # model_provider[...] while the create-mode ones send %{"value"} —
  # resolve_scope_search/1 accepts both shapes.
  def handle_event("scope_group_search", params, socket) do
    %{search: search} = resolve_scope_search(params)

    {:noreply,
     socket
     |> assign(:scope_group_search, search)
     |> assign(:scope_group_open, search != "")}
  end

  def handle_event("scope_member_search", params, socket) do
    %{search: search} = resolve_scope_search(params)

    {:noreply,
     socket
     |> assign(:scope_member_search, search)
     |> assign(:scope_member_open, search != "")}
  end

  # Single-select picks — used when editing an existing row (one target).
  # Reflect the picked label into the search input and close the dropdown.
  def handle_event(
        "select_scope_group_item",
        %{"group_id" => group_id, "group_label" => group_label},
        socket
      ) do
    if socket.assigns.is_admin do
      {:noreply,
       socket
       |> assign(:current_scope_group_id, group_id)
       |> assign(:scope_group_search, group_label)
       |> assign(:scope_group_open, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "select_scope_member_item",
        %{"member_id" => member_id, "member_label" => member_label},
        socket
      ) do
    if socket.assigns.is_admin do
      {:noreply,
       socket
       |> assign(:current_scope_member_id, member_id)
       |> assign(:scope_member_search, member_label)
       |> assign(:scope_member_open, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_scope_picker", %{"picker" => "group"}, socket) do
    if socket.assigns.is_admin do
      {:noreply, assign(socket, :scope_group_open, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_scope_picker", %{"picker" => "member"}, socket) do
    if socket.assigns.is_admin do
      {:noreply, assign(socket, :scope_member_open, true)}
    else
      {:noreply, socket}
    end
  end

  # Shared closer: fired by phx-click-away on each picker wrapper and by
  # Escape (form-level phx-window-keydown filtered to phx-key="Escape").
  def handle_event("close_scope_pickers", _params, socket) do
    if socket.assigns.is_admin do
      {:noreply,
       socket
       |> assign(:scope_group_open, false)
       |> assign(:scope_member_open, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)
      new_enabled = !ap.enabled

      case Providers.update_model_provider(ap, %{enabled: new_enabled}) do
        {:ok, _} ->
          audit(socket, "model_provider.toggle_status", "model_provider", ap.id, %{
            "model_id" => ap.model_id,
            "enabled" => new_enabled
          })

          {:noreply,
           socket
           |> put_flash(
             :info,
             if(new_enabled,
               do: gettext("Provider activated."),
               else: gettext("Provider deactivated.")
             )
           )
           |> load_models()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the provider."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("delete_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)

      case Providers.delete_model_provider(ap) do
        {:ok, _} ->
          audit(socket, "model_provider.delete", "model_provider", ap.id, %{
            "model_id" => ap.model_id
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Provider removed from the model."))
           |> load_models()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete the provider."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("reorder_providers", %{"model_id" => model_id, "ids" => ids}, socket) do
    if socket.assigns.is_admin do
      valid_ids =
        from(ap in ModelProvider, where: ap.model_id == ^model_id, select: ap.id)
        |> Repo.all()
        |> MapSet.new()

      if is_list(ids) and ids != [] and Enum.all?(ids, &MapSet.member?(valid_ids, &1)) do
        {:ok, _} =
          Repo.transaction(fn ->
            ids
            |> Enum.with_index(1)
            |> Enum.each(fn {ap_id, priority} ->
              from(ap in ModelProvider, where: ap.id == ^ap_id)
              |> Repo.update_all(
                set: [
                  priority: priority,
                  updated_at: DateTime.truncate(DateTime.utc_now(), :second)
                ]
              )
            end)
          end)

        audit(socket, "model_provider.reorder", "model", model_id, %{"ids" => ids})

        {:noreply, load_models(socket)}
      else
        {:noreply, put_flash(socket, :error, gettext("Invalid order for this model."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  ## Private helpers — wizard ----------------------------------------------

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

  @doc "Los modelos de servicio que un proveedor publica para el tipo elegido."
  def media_models_for(provider_key, type) do
    if ServiceModels.media_type?(type) do
      ServiceModels.known_ids(provider_key, type)
    else
      []
    end
  end

  @doc """
  La referencia con la que el wizard identifica un proveedor: su `key` (el
  vínculo con el catálogo) o, para un custom que no tiene, su `id`.
  """
  def wizard_provider_ref(provider), do: provider.key || provider.id

  @doc "Resumen del lane que el wizard va a crear: proveedor · id del modelo."
  def wizard_lane_summary(provider_label, provider_model) do
    case provider_model do
      pm when is_binary(pm) and pm != "" -> "#{provider_label} · #{pm}"
      _ -> provider_label
    end
  end

  @doc "Etiqueta de una credencial en el select del wizard: alias (sufijo de la key)."
  def credential_label(credential) do
    name = credential.name || gettext("Key")

    case credential.api_key_encrypted do
      key when is_binary(key) -> "#{name} (#{mask_key(key)})"
      _ -> name
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

  defp provider_label_for(socket, provider_ref) do
    case Enum.find(List.wrap(socket.assigns[:wizard_providers]), fn provider ->
           wizard_provider_ref(provider) == provider_ref
         end) do
      %{name: name} when is_binary(name) -> name
      _ -> provider_ref
    end
  end

  # El catálogo del paso 2 tiene DOS fuentes y se combinan: la semilla
  # (instantánea, verificada, funciona sin red) y el listado EN VIVO del
  # proveedor cuando publica catálogo por servicio (`ServiceModels.discovery/2`).
  # El resultado se empuja por mensaje: `list_models_at/3` es una llamada HTTP y
  # bloquear el `handle_event` del modal dejaría la UI congelada.
  defp fetch_wizard_service_models(socket, provider_key, type) do
    case ServiceModels.discovery(provider_key, type) do
      nil ->
        socket

      endpoint ->
        case socket.assigns[:wizard_credentials] || [] do
          [] ->
            # Sin API key no se puede autenticar el listado: la semilla se queda
            # como catálogo y el "New API key" queda a la vista en el paso 3.
            assign(socket, :wizard_media_models_loading, false)

          [credential | _] ->
            provider = credential.provider
            lv_pid = self()

            Task.start(fn ->
              result =
                ProviderAdapter.dispatch(provider).list_service_models(
                  provider,
                  credential,
                  endpoint
                )

              send(lv_pid, {:wizard_service_models, provider_key, type, result})
            end)

            assign(socket, :wizard_media_models_loading, true)
        end
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

  ## Private helpers — model save ------------------------------------------

  # El wizard crea el modelo Y su primer lane de una vez: el operador ya eligió
  # proveedor (y por tanto la credencial) antes de llegar a los datos del
  # modelo. Sin proveedor elegido — o sin ninguna API key suya — el modelo se
  # crea igual y el lane se añade después desde la fila (el modal de siempre).
  #
  # La unidad de precio del lane nace con la del TIPO del modelo, para que el
  # operador no tenga que acordarse de cambiarla.
  defp create_wizard_lane(socket, model) do
    with credential_id when is_binary(credential_id) <- socket.assigns[:wizard_credential_id],
         provider_model when is_binary(provider_model) <- socket.assigns[:wizard_provider_model] do
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
        |> put_offer_prices(offer_for_wizard(socket), unit)

      case Providers.create_model_provider(attrs) do
        {:ok, ap} ->
          audit(socket, "model_provider.create", "model_provider", ap.id, %{
            "model_id" => model.id,
            "provider_model" => provider_model,
            "via" => "wizard"
          })

          :ok

        {:error, _changeset} ->
          :error
      end
    else
      _ -> :error
    end
  end

  # El precio de LISTA del catálogo entra como fallback manual del lane. No es un
  # detalle: hay proveedores que NO reportan coste — Jev (TypeSafe) es el caso
  # canónico, su API no devuelve `usage.cost` — y sin este precio el lane nace
  # cobrando $0 aunque el catálogo sí sepa cuánto cuesta.
  #
  # Sólo aplica a las unidades de TOKEN, que son las que leen los tres campos
  # `*_cost_per_million`; un lane de servicio se cobra con `unit_cost`, y para
  # eso el catálogo no tiene dato.
  defp put_offer_prices(attrs, %{} = offer, unit) do
    if Pricing.token_unit?(unit) do
      attrs
      |> Map.put(:input_cost_per_million, Map.get(offer, :cost_input))
      |> Map.put(:output_cost_per_million, Map.get(offer, :cost_output))
      |> Map.put(:cache_cost_per_million, Map.get(offer, :cost_cache_read))
    else
      attrs
    end
  end

  defp put_offer_prices(attrs, _offer, _unit), do: attrs

  # La oferta del proveedor elegido para el modelo elegido: de ahí sale el precio
  # de lista que `put_offer_prices/3` copia. Sólo existe cuando el modelo vino
  # del catálogo (models.dev) — un modelo de servicio no está ahí.
  defp offer_for_wizard(socket) do
    with key when is_binary(key) <- socket.assigns[:wizard_provider_key],
         form when form != nil <- socket.assigns[:form],
         catalog_key when is_binary(catalog_key) <-
           Ecto.Changeset.get_field(form.source, :catalog_model_key) do
      Providers.offer_for(catalog_key, key)
    else
      _ -> nil
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
    |> assign(:wizard_media_models, [])
    |> assign(:wizard_media_models_loading, false)
  end

  defp save_model(socket, :new, model_params) do
    case Providers.create_model(model_params) do
      {:ok, model} ->
        audit(socket, "model.create", "model", model.id, %{"name" => model.name})

        lane? = create_wizard_lane(socket, model) == :ok

        message =
          if lane? do
            gettext("Model created with its first provider assignment.")
          else
            gettext("Model created.")
          end

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(:form, nil)
         |> assign(:editing_model_id, nil)
         |> reset_wizard()
         |> load_models()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
    end
  end

  defp save_model(socket, model_id, model_params) when is_binary(model_id) do
    model_record = Providers.get_model!(model_id)

    case Providers.update_model(model_record, model_params) do
      {:ok, updated} ->
        audit(socket, "model.update", "model", updated.id, %{
          "name" => updated.name,
          "changes" =>
            Map.take(model_params, [
              "name",
              "context_window",
              "model_type",
              "catalog_model_key",
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

  ## Private helpers — model_provider save ---------------------------------

  # Search events arrive from inputs inside the provider form: create-mode
  # pickers carry %{"value"}, while the named edit-mode ones arrive nested
  # under their model_provider[...] field name.
  defp resolve_scope_search(%{"value" => search}), do: %{search: search}

  defp resolve_scope_search(%{"model_provider" => %{"value" => search}}),
    do: %{search: search}

  defp resolve_scope_search(%{"model_provider" => %{"scope_member_id_display" => search}}),
    do: %{search: search || ""}

  defp resolve_scope_search(%{"model_provider" => %{"scope_group_id_display" => search}}),
    do: %{search: search || ""}

  defp resolve_scope_search(_params), do: %{search: ""}

  defp inject_scope_params(ap_params, assigns) do
    scope = assigns[:current_scope] || "global"
    editing? = is_binary(assigns[:editing_ap_id]) and assigns[:editing_ap_id] != :new

    case scope do
      "member" ->
        if editing? do
          ap_params
          |> Map.put("exclusive_to_group_member_id", assigns[:current_scope_member_id])
          |> Map.put("exclusive_to_group_id", nil)
        else
          ap_params
          |> Map.put("exclusive_to_group_member_ids", assigns[:current_scope_member_ids] || [])
          |> Map.put("exclusive_to_group_id", nil)
        end

      "group" ->
        if editing? do
          ap_params
          |> Map.put("exclusive_to_group_member_id", nil)
          |> Map.put("exclusive_to_group_id", assigns[:current_scope_group_id])
        else
          ap_params
          |> Map.put("exclusive_to_group_member_id", nil)
          |> Map.put("exclusive_to_group_ids", assigns[:current_scope_group_ids] || [])
        end

      _ ->
        ap_params
        |> Map.put("exclusive_to_group_member_id", nil)
        |> Map.put("exclusive_to_group_id", nil)
    end
  end

  defp fetch_provider_models(socket, credential_id) do
    credential =
      Enum.find(socket.assigns.credentials_for_select, &(&1.id == credential_id))

    if credential do
      provider = credential.provider

      model_type = model_type_for(socket.assigns[:provider_form_model_id])

      lv_pid = self()

      Task.start(fn ->
        adapter = Tokengate.Proxy.ProviderAdapter.dispatch(provider)

        result =
          if model_type == "embedding" do
            adapter.list_embedding_models(provider, credential)
          else
            Tokengate.Proxy.OpenAIAdapter.list_models(provider, credential)
          end

        send(lv_pid, {:provider_models_result, credential_id, result})
      end)

      socket
    else
      socket
      |> assign(:provider_models, [])
      |> assign(:provider_models_loading, false)
      |> assign(:provider_model_search, "")
    end
  end

  @impl true
  def handle_info(
        {:provider_models_result, credential_id, result},
        %{assigns: assigns} = socket
      ) do
    # Discard stale responses: only the most recent credential change wins.
    if credential_id == assigns[:provider_form_credential_id] do
      case result do
        {:ok, models} ->
          {:noreply,
           socket
           |> assign(:provider_models, models)
           |> assign(:provider_models_loading, false)
           |> assign(:provider_model_search, "")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:provider_models, [])
           |> assign(:provider_models_loading, false)
           |> assign(:provider_model_search, "")
           |> put_flash(:error, gettext("Could not load the provider models."))}
      end
    else
      {:noreply, socket}
    end
  end

  # Resultado del listado EN VIVO del paso 2 (el proveedor publica catálogo por
  # servicio). Se descarta si el operador ya cambió de proveedor o de tipo — la
  # respuesta llegaría tarde y pisaría una lista que ya no es la suya.
  @impl true
  def handle_info(
        {:wizard_service_models, provider_key, type, result},
        %{assigns: assigns} = socket
      ) do
    if assigns[:wizard_provider_key] == provider_key and
         assigns[:model_form_picked_type] == type do
      {:noreply,
       socket
       |> assign(:wizard_media_models_loading, false)
       |> assign(
         :wizard_media_models,
         merge_wizard_models(assigns[:wizard_media_models] || [], result)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  # Per-provider defaults applied on every save (create and edit). The form
  # no longer surfaces raw overrides; this keeps the stored columns coherent:
  #
  #   * extra_body / omit_* — the UI can't set them anymore (schema fields
  #     stay for programmatic use); only the service_tier checkbox writes
  #     extra_body, via the changeset.
  defp apply_provider_defaults(ap_params, _socket) do
    Map.drop(ap_params, ["extra_body_json", "omit_body_fields_csv", "omit_headers_csv"])
  end

  defp save_model_provider(socket, :new, ap_params) do
    ap_params = Map.put(ap_params, "model_id", socket.assigns.provider_form_model_id)

    # Per-provider defaults the form no longer asks for: the raw extra_body
    # override is not submittable from the UI anymore — the service_tier
    # checkbox owns extra_body's only managed key.
    ap_params = apply_provider_defaults(ap_params, socket)

    # Extract multi-select target lists (set by inject_scope_params for create mode)
    group_ids = Map.get(ap_params, "exclusive_to_group_ids", [])
    member_ids = Map.get(ap_params, "exclusive_to_group_member_ids", [])

    # Clean the params — remove the plural keys before inserting
    ap_params =
      ap_params
      |> Map.delete("exclusive_to_group_ids")
      |> Map.delete("exclusive_to_group_member_ids")

    # Build the list of insert targets: one set of params per group/member.
    # Global scope = single insert with no exclusive FK. Group/member scope
    # with empty selection = error (must pick at least one).
    targets =
      cond do
        group_ids != [] ->
          Enum.map(group_ids, fn id ->
            Map.merge(ap_params, %{
              "exclusive_to_group_id" => id,
              "exclusive_to_group_member_id" => nil
            })
          end)

        member_ids != [] ->
          Enum.map(member_ids, fn id ->
            Map.merge(ap_params, %{
              "exclusive_to_group_id" => nil,
              "exclusive_to_group_member_id" => id
            })
          end)

        Map.get(ap_params, "exclusive_to_group_id") != nil or
            Map.get(ap_params, "exclusive_to_group_member_id") != nil ->
          # Single target from edit mode — already in singular keys
          [ap_params]

        true ->
          # Global scope
          [ap_params]
      end

    # Validate: group/member scope must have at least one target selected
    scope = socket.assigns[:current_scope] || "global"

    cond do
      (scope == "group" or scope == "member") and targets == [] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Select at least one limit profile or user for the exclusive scope.")
         )}

      true ->
        # Los inserts van en una sola transacción: si un target choca con el
        # índice de exclusividad única (mismo modelo+target ya tiene dueño),
        # no debe quedar un estado parcial con la mitad de los targets
        # asignados. O entran todos, o ninguno.
        results =
          Providers.create_model_providers_transactional(targets)

        case results do
          {:ok, count} ->
            msg =
              if count == 1,
                do: gettext("Provider assigned to the model."),
                else: gettext("%{count} providers assigned to the model.", count: count)

            audit(
              socket,
              "model_provider.create",
              "model",
              socket.assigns.provider_form_model_id,
              %{
                "count" => count,
                "scope" => scope
              }
            )

            {:noreply,
             socket
             |> put_flash(:info, msg)
             |> assign(:provider_form, nil)
             |> assign(:editing_ap_id, nil)
             |> load_models()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("Could not assign: %{errors}",
                 errors: Enum.map_join(changeset.errors, ", ", fn {_f, {m, _}} -> m end)
               )
             )
             |> assign(:provider_form, to_form(changeset, as: :model_provider))}
        end
    end
  end

  defp save_model_provider(socket, ap_id, ap_params) when is_binary(ap_id) do
    ap = Providers.get_model_provider!(ap_id)
    ap_params = apply_provider_defaults(ap_params, socket)

    case Providers.update_model_provider(ap, ap_params) do
      {:ok, updated_ap} ->
        audit(socket, "model_provider.update", "model_provider", updated_ap.id, %{
          "model_id" => updated_ap.model_id,
          "changes" =>
            Map.take(ap_params, [
              "provider_model",
              "enabled",
              "priority",
              "exclusive_to_group_id",
              "exclusive_to_group_member_id"
            ])
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Provider updated."))
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_models()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :model_provider))}
    end
  end

  ## Private helpers — search params ----------------------------------------

  # Search inputs live inside the modal's forms, so the payload shape depends on
  # where the input sits: a bare `name="value"` input sends `%{"value" => typed}`,
  # while one nested under a form's field name arrives as
  # `%{"model_provider" => %{"value" => typed}}`. Both are accepted, so the
  # pickers keep working wherever they are placed in the template.
  defp query_param(params) when is_map(params) do
    params
    |> Enum.flat_map(fn
      {_key, %{} = nested} -> Map.to_list(nested)
      {key, value} -> [{key, value}]
    end)
    |> Enum.find_value("", fn
      {key, value} when key in ["value", "q"] and is_binary(value) -> value
      _ -> nil
    end)
  end

  defp query_param(_), do: ""

  ## Private helpers — model catalog picker ----------------------------------

  # The catalog list is loaded the first time a picker opens (~3000 compact rows,
  # filtered in memory: that is what makes every keystroke instant) and cached
  # for the life of the LiveView, so opening the modal twice costs one query.
  defp ensure_catalog_models(%{assigns: %{catalog_models: models}} = socket)
       when is_list(models),
       do: socket

  defp ensure_catalog_models(socket) do
    # El dropdown de proveedores nace YA acotado por el tipo elegido: el tipo
    # decide qué proveedores pueden servir el modelo (l. del paso 0), y ofrecer
    # un proveedor que no declara la capability es un callejón sin salida.
    type = socket.assigns[:model_form_picked_type]

    socket
    |> assign(:catalog_models, Providers.catalog_picker_models())
    |> assign(:catalog_picker_providers, Providers.catalog_picker_providers(type))
    |> assign(:catalog_provider_filter, nil)
    |> assign(:catalog_keys_taken, Providers.registered_catalog_model_keys())
    |> assign(:lab_logos, lab_logos())
  end

  defp lab_logos do
    Providers.list_labs(source: "builtin")
    |> Map.new(fn lab -> {lab.key, lab.logo_url} end)
  end

  defp filter_catalog_models(socket, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()
    models = socket.assigns[:catalog_models] || []

    # El tipo elegido en el paso 0 acota el catálogo: llm/embedding/decision por
    # el hint del id; los seis servicios de media NO existen en models.dev (no
    # publica esos modelos), así que su lista del mirror es vacía a propósito —
    # sus modelos salen del catálogo del proveedor, no de aquí.
    type = socket.assigns[:model_form_picked_type]
    models = filter_catalog_by_type(models, type)

    # Cuántos modelos hay del tipo elegido (antes del filtro de proveedor): es
    # el número que el badge y el pie del picker deben mostrar, no el total del
    # mirror entero — que para un servicio de media era puro ruido.
    type_count = length(models)

    # El filtro de proveedor (dropdown del picker) acota además por quién
    # sirve el modelo: los offers activos del mirror.
    models = filter_catalog_by_provider(models, socket.assigns[:catalog_provider_filter])

    results =
      if needle == "" do
        Enum.take(models, @catalog_results_limit)
      else
        models
        |> Enum.filter(fn model ->
          String.contains?(String.downcase(model.name || ""), needle) or
            String.contains?(String.downcase(model.key), needle) or
            String.contains?(model.lab_key || "", needle)
        end)
        |> Enum.take(@catalog_results_limit)
      end

    socket
    |> assign(:catalog_query, query)
    |> assign(:catalog_results, results)
    |> assign(:catalog_type_count, type_count)
  end

  # nil = todos los proveedores (default del dropdown).
  defp filter_catalog_by_provider(models, nil), do: models

  defp filter_catalog_by_provider(models, provider_key) when is_binary(provider_key) do
    Enum.filter(models, &(provider_key in (model_providers(&1) || [])))
  end

  defp filter_catalog_by_provider(models, _), do: models

  # `provider_keys` viene en los entries del picker (catalog_picker_models);
  # tolerar su ausencia mantiene el helper utilizable con cualquier mapa.
  defp model_providers(%{provider_keys: keys}), do: keys
  defp model_providers(_), do: []

  # El tipo elegido acota el mirror con UNA regla: el hint del id tiene que ser
  # exactamente el tipo pedido.
  #
  # Los tres tipos que models.dev sí conoce (llm, embedding, decision) se
  # resuelven con el hint; los SEIS servicios de media (rerank, stt, tts, image,
  # video, music) no existen en models.dev, así que el mirror no tiene filas de
  # ese tipo y el resultado es la lista VACÍA.
  #
  # Antes la cláusula de servicio era `do: models`, que devolvía TODO el catálogo
  # (~3000 modelos de chat) al elegir "Transcription" — el bug reportado.
  # Sin tipo elegido (edición de un row anterior al paso 0, o cualquier camino
  # que no pase por el picker) no se acota nada: el catálogo se ofrece entero,
  # que es el comportamiento histórico.
  defp filter_catalog_by_type(models, nil), do: models

  defp filter_catalog_by_type(models, type) when type in ~w(llm embedding decision) do
    hint = &Tokengate.Providers.ModelCatalog.model_type_hint(&1.key)
    Enum.filter(models, &(hint.(&1) == type))
  end

  defp filter_catalog_by_type(_models, _media_type), do: []

  # Cuántos modelos del mirror son del tipo pedido: el número honesto del badge
  # y del pie del picker (el total del mirror entero no dice nada útil).
  defp catalog_type_count(nil, _type), do: 0

  defp catalog_type_count(models, type) when is_list(models) do
    models |> filter_catalog_by_type(type) |> length()
  end

  @doc """
  A DOM-id-safe, INJECTIVE rendering of a catalog/provider key.

  models.dev ids carry `/`, `@`, `:`, `~` and `.` (`openai/gpt-5-nano`,
  `@cf/meta/llama-3.1-8b-instruct`, `glm-5.2`), none of which are valid in a CSS
  selector: a raw id would break every `element/2` lookup and any client-side
  selector.

  A plain substitution is NOT enough: `/` and `-` both collapse to `-` (and `.`
  to `_`), so `openai/gpt-5-nano` and `openai-gpt-5-nano` — two DISTINCT rows the
  mirror really holds — rendered the same DOM id and LiveView raised
  `Duplicate id found` on the modal. The snapshot has 57 such pairs.

  So the sanitized form is kept for readability and, whenever the key was
  rewritten at all, a short hash of the ORIGINAL key is appended: the transform
  stays injective (`dom_key/1` of two different keys never collides — verified
  against every id in the vendored catalog) while a human can still read the
  prefix. A key already made of `[A-Za-z0-9_-]` is returned untouched, so
  provider keys like `fireworks-ai` keep their plain id.
  """
  def dom_key(key) when is_binary(key) do
    sanitized = sanitize_dom_key(key)

    if sanitized == key do
      sanitized
    else
      sanitized <> "-" <> key_hash(key)
    end
  end

  def dom_key(key), do: to_string(key)

  defp sanitize_dom_key(key) do
    key
    |> String.replace(".", "_")
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp key_hash(key) do
    :sha256
    |> :crypto.hash(key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc "True when a `models` row was already created from this catalog entry."
  def catalog_taken?(taken, key), do: MapSet.member?(taken || MapSet.new(), key)

  @doc "models.dev logo URL for a lab key (nil when the lab has none)."
  def lab_logo(logos, lab_key), do: Map.get(logos || %{}, lab_key)

  @doc "Display name of a provider in the modal's choice list (id as fallback)."
  def provider_label(choices, provider_key) do
    choices
    |> List.wrap()
    |> Enum.find(&(&1.provider.key == provider_key))
    |> case do
      %{provider: provider} -> provider.name
      _ -> provider_key
    end
  end

  @doc """
  Nombre del proveedor elegido en el modal. Sale de la lista de ofertas del
  modelo; una key de un proveedor que no sirve este modelo no entra a esa lista,
  así que se resuelve por la credencial (el proveedor siempre es conocido: es
  quien emitió la key).
  """
  def provider_chip_name(choices, credentials, provider_key) do
    case Enum.find(List.wrap(choices), &(&1.provider.key == provider_key)) do
      %{provider: provider} ->
        provider.name

      _ ->
        case Enum.find(List.wrap(credentials), &(&1.provider.key == provider_key)) do
          %{provider: %{name: name}} when is_binary(name) -> name
          _ -> provider_key
        end
    end
  end

  ## Componentes — marca del modelo -------------------------------------------

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
        "Marca del lab #{lab.name}."

      nil ->
        case form[:icon].value do
          icon when is_binary(icon) and icon != "" -> gettext("The model's own icon.")
          _ -> gettext("Generic icon: link a lab or pick one from the palette.")
        end
    end
  end

  ## Private helpers — provider + credentials --------------------------------

  # Which providers the modal offers: the ones that serve the model according to
  # models.dev when the model came from the catalog, else every active provider —
  # a hand-made model has no offer to narrow by.
  defp build_provider_choices(socket, model_id) do
    choices =
      case Providers.get_model(model_id) do
        %Model{catalog_model_key: key} when is_binary(key) -> Providers.providers_serving(key)
        _ -> all_active_providers()
      end

    # El tipo elegido en el paso 0 acota además por capability declarada: solo
    # proveedores que sirven ese servicio aparecen. Un tipo no elegido (edición
    # de un row existente) no filtra — el comportamiento previo se conserva.
    choices =
      case socket.assigns[:model_form_picked_type] do
        nil -> choices
        type -> filter_choices_by_capability(choices, type)
      end

    socket
    |> assign(:provider_choices, choices)
    |> filter_provider_choices("")
  end

  # llm/embedding son capabilities declaradas; los seis servicios también lo
  # son en el vocabulario de `Catalog`. Un proveedor custom (sin catalog key)
  # no declara nada: se mantiene visible para no bloquear el alta manual.
  defp filter_choices_by_capability(choices, capability) do
    choices
    |> Enum.filter(fn
      %{provider: %Provider{key: key}} when is_binary(key) ->
        case Tokengate.Providers.Catalog.capabilities(key) do
          [] -> true
          caps -> capability in caps
        end

      _ ->
        true
    end)
  end

  defp all_active_providers do
    from(p in Provider,
      where: p.status == "active",
      order_by: [asc: p.name],
      preload: [:credentials]
    )
    |> Repo.all()
    |> Enum.map(&%{provider: &1, offer: nil})
  end

  defp filter_provider_choices(socket, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()
    choices = socket.assigns[:provider_choices] || []

    results =
      if needle == "" do
        Enum.take(choices, @provider_results_limit)
      else
        choices
        |> Enum.filter(fn %{provider: provider} ->
          String.contains?(String.downcase(provider.name || ""), needle) or
            String.contains?(String.downcase(provider.key || ""), needle)
        end)
        |> Enum.take(@provider_results_limit)
      end

    socket
    |> assign(:provider_search, query)
    |> assign(:provider_choices_results, results)
  end

  defp selected_provider(socket) do
    case socket.assigns[:provider_form_provider_key] do
      nil ->
        nil

      key ->
        socket.assigns[:provider_choices]
        |> List.wrap()
        |> Enum.find(&(&1.provider.key == key))
        |> case do
          %{provider: provider} -> provider
          _ -> nil
        end
    end
  end

  defp selected_offer(socket, provider_key) do
    socket.assigns[:provider_choices]
    |> List.wrap()
    |> Enum.find(&(&1.provider.key == provider_key))
    |> case do
      %{offer: offer} -> offer
      _ -> nil
    end
  end

  defp credentials_of(socket, provider_id) do
    (socket.assigns[:credentials_for_select] || [])
    |> Enum.filter(&(&1.provider_id == provider_id))
  end

  # The credential the modal keeps selected after picking a provider: the one it
  # already had when it still belongs to that provider, else the provider's only
  # key, else nothing (the operator chooses).
  defp keep_or_default_credential(socket, credentials) do
    current = socket.assigns[:provider_form_credential_id]

    if current && Enum.any?(credentials, &(&1.id == current)) do
      current
    else
      default_credential_id(credentials)
    end
  end

  defp default_credential_id([single]), do: single.id
  defp default_credential_id(_), do: nil

  defp provider_key_of_credential(_socket, nil), do: nil

  defp provider_key_of_credential(socket, credential_id) do
    case Enum.find(socket.assigns[:credentials_for_select] || [], &(&1.id == credential_id)) do
      %{provider: %{key: key}} -> key
      _ -> nil
    end
  end

  # One place where picking a provider (or creating its key) turns into modal
  # state: the form's credential, the provider's own model id and the models.dev
  # prices as the manual fallback, the credential list narrowed to that provider,
  # and the provider's live catalogue loaded for the suggestion list.
  defp apply_offer(socket, provider, offer, credentials, changeset, credential_id) do
    socket =
      socket
      |> assign(
        :provider_form,
        to_form(put_offer_defaults(changeset, offer), as: :model_provider)
      )
      |> assign(:provider_form_provider_key, provider.key)
      |> assign(:provider_form_credential_id, credential_id)
      |> assign(:provider_form_is_fireworks, provider.key == "fireworks-ai")
      |> assign(:provider_credentials, credentials)
      |> assign_credential_choices()

    if credentials == [] do
      socket
      |> assign(:provider_models, [])
      |> assign(:provider_models_loading, false)
    else
      socket
      |> assign(:provider_models_loading, true)
      |> fetch_provider_models(credential_id)
    end
  end

  defp put_offer_defaults(changeset, nil), do: changeset

  defp put_offer_defaults(changeset, offer) do
    changeset
    |> put_new_change(:provider_model, offer.provider_model)
    |> put_new_change(:input_cost_per_million, offer.cost_input)
    |> put_new_change(:output_cost_per_million, offer.cost_output)
    |> put_new_change(:cache_cost_per_million, offer.cost_cache_read)
  end

  # Elegir la API key es lo que fija la relación modelo↔proveedor: cada
  # credencial pertenece a un solo proveedor, así que la key resuelve por sí
  # sola el proveedor del modal. Si ese proveedor publica una oferta para este
  # modelo (models.dev), su `provider_model` y su precio de lista entran como
  # defaults de los campos vacíos.
  defp apply_credential_provider(socket, credential_id, ap_params) do
    case Enum.find(socket.assigns[:credentials_for_select] || [], &(&1.id == credential_id)) do
      %{provider: provider} ->
        credentials = credentials_of(socket, provider.id)

        changeset =
          socket.assigns.provider_form.source
          |> carry_submitted_params(ap_params)
          |> Ecto.Changeset.put_change(:credential_id, credential_id)
          |> put_offer_defaults(
            offer_for_provider(socket.assigns[:provider_form_model_id], provider.key)
          )

        socket
        |> assign(:provider_form, to_form(changeset, as: :model_provider))
        |> assign(:provider_form_provider_key, provider.key)
        |> assign(:provider_form_credential_id, credential_id)
        |> assign(:provider_form_is_fireworks, provider.key == "fireworks-ai")
        |> assign(:provider_credentials, credentials)
        |> assign_credential_choices()

      _ ->
        socket
    end
  end

  # phx-change manda TODOS los campos del form, y ese envío es el estado real
  # del modal: el changeset del último render puede estar viejo. Se vuelca sin
  # correr validaciones (un requerido aún vacío no debe pintar error a medio
  # llenar) y solo para los campos que el form realmente mandó.
  defp carry_submitted_params(changeset, params) do
    fields =
      changeset.types
      |> Map.keys()
      |> Enum.reject(&(&1 in [:id, :model_id, :inserted_at, :updated_at]))
      |> Enum.filter(&Map.has_key?(params, Atom.to_string(&1)))

    Ecto.Changeset.cast(changeset, params, fields)
  end

  # La oferta de models.dev de UN proveedor para el modelo del modal: nil si el
  # modelo no viene del catálogo o si ese proveedor no lo sirve.
  defp offer_for_provider(model_id, provider_key) when is_binary(provider_key) do
    case Providers.get_model(model_id) do
      %Model{catalog_model_key: key} when is_binary(key) -> Providers.offer_for(key, provider_key)
      _ -> nil
    end
  end

  defp offer_for_provider(_model_id, _provider_key), do: nil

  # An offer fills a field only while it is empty: what the operator typed (or an
  # existing row being edited) always wins.
  defp put_new_change(changeset, _field, nil), do: changeset

  defp put_new_change(changeset, field, value) do
    if Ecto.Changeset.get_field(changeset, field) == nil do
      Ecto.Changeset.put_change(changeset, field, value)
    else
      changeset
    end
  end

  # The credentials the modal's select lists: just the selected provider's keys
  # once a provider is chosen, every active credential until then.
  defp assign_credential_choices(socket) do
    choices =
      case socket.assigns[:provider_form_provider_key] do
        nil -> socket.assigns[:credentials_for_select] || []
        _ -> socket.assigns[:provider_credentials] || []
      end

    assign(socket, :credential_choices, choices)
  end

  ## Helpers ---------------------------------------------------------------

  # True when the form's selected credential belongs to the Fireworks
  # provider (catalog key "fireworks-ai"). Gates the service_tier checkbox —
  # Priority is a Fireworks-only serving path.
  defp credential_is_fireworks?(credential_id, socket) when is_binary(credential_id) do
    case Enum.find(socket.assigns.credentials_for_select, &(&1.id == credential_id)) do
      %{provider: %{key: "fireworks-ai"}} -> true
      _ -> false
    end
  end

  defp credential_is_fireworks?(_, _socket), do: false

  @doc "Credential options for the select (id -> display)"
  def credential_options(credentials) do
    Enum.map(credentials, fn c ->
      label =
        if c.name do
          "#{c.provider.name} · #{c.name} · #{mask_key(c.api_key_encrypted)}"
        else
          "#{c.provider.name} · #{mask_key(c.api_key_encrypted)}"
        end

      {label, c.id}
    end)
  end

  @doc "Mask an api key for display: show only the last 4 chars."
  def mask_key(nil), do: "—"
  def mask_key(""), do: "—"
  def mask_key(key) when byte_size(key) <= 4, do: "****"

  def mask_key(key) do
    len = String.length(key)

    String.slice(key, len - 4, 4)
    |> then(&"••••••#{&1}")
  end

  @doc "Format a decimal for display"
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc """
  Format a price compactly for the picker rows: trims trailing zeros
  ("1.250000" -> "1.25"). Display-only. Deliberately avoids
  Decimal.normalize, which emits scientific notation for whole numbers
  ("10.000000" -> "1E+1").
  """
  def fmt_price(nil), do: "—"

  def fmt_price(%Decimal{} = d) do
    s = Decimal.to_string(d)

    if String.contains?(s, ".") do
      s |> String.trim_trailing("0") |> String.trim_trailing(".")
    else
      s
    end
  end

  def fmt_price(n), do: fmt_dec(n)

  @doc "Empty-state message for the models list"
  def empty_state_message, do: "No hay models configurados."

  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  @doc "Scope badge CSS class"
  def scope_badge(%ModelProvider{exclusive_to_group_member_id: id}) when not is_nil(id),
    do: "badge-warning"

  def scope_badge(%ModelProvider{exclusive_to_group_id: id}) when not is_nil(id),
    do: "badge-info"

  def scope_badge(%ModelProvider{}), do: "badge-ghost"
  def scope_badge("member"), do: "badge-warning"
  def scope_badge("group"), do: "badge-info"
  def scope_badge(_), do: "badge-ghost"

  @doc "Scope badge label"
  def scope_label(%ModelProvider{exclusive_to_group_member_id: id}) when not is_nil(id),
    do: gettext("Member exclusive")

  def scope_label(%ModelProvider{exclusive_to_group_id: id}) when not is_nil(id),
    do: gettext("Limit profile exclusive")

  def scope_label(%ModelProvider{}), do: "Global"
  def scope_label("member"), do: gettext("Member exclusive")
  def scope_label("group"), do: gettext("Limit profile exclusive")
  def scope_label(_), do: "Global"

  @doc "Resolve scope to human-readable label with target name"
  def scope_target_label(%ModelProvider{} = mp, assigns) do
    cond do
      mp.exclusive_to_group_member_id ->
        member =
          Enum.find(assigns.members_for_select || [], &(&1.id == mp.exclusive_to_group_member_id))

        if member && member.user, do: member.user.email, else: gettext("Member")

      mp.exclusive_to_group_id ->
        group = Enum.find(assigns.groups_for_select || [], &(&1.id == mp.exclusive_to_group_id))
        if group, do: group.name, else: gettext("Limit profile")

      true ->
        "Todos"
    end
  end

  def model_providers_for(model) do
    model.model_providers || []
  end

  @doc """
  Client-side toggle for an model card's providers section. Kept in JS so the
  collapse/expand state lives purely in the DOM — server round-trips (and the
  associated stream re-render) are unnecessary for a show/hide toggle.
  """
  def toggle_providers_js(id) do
    JS.toggle(to: "#model-providers-#{id}", display: "block")
    |> JS.toggle_class("rotate-90", to: "#model-chevron-#{id}")
  end

  @doc """
  Group key for scope grouping in the UI: 0 = global, 1 = group-exclusive,
  2 = member-exclusive. Matches the SQL ordering in load_models/1.
  """
  def scope_group(%ModelProvider{exclusive_to_group_member_id: id}) when not is_nil(id), do: 2
  def scope_group(%ModelProvider{exclusive_to_group_id: id}) when not is_nil(id), do: 1
  def scope_group(%ModelProvider{}), do: 0

  @doc "Group header label (nil for the global group — no header needed)"
  def scope_group_label(1), do: gettext("Exclusive per limit profile")
  def scope_group_label(2), do: gettext("Exclusive per user")
  def scope_group_label(_), do: nil

  def provider_name(%ModelProvider{credential: %{provider: provider}}) when not is_nil(provider),
    do: provider.name

  def provider_name(_), do: "—"

  def credential_named?(%{name: name}) when is_binary(name) and name != "", do: true
  def credential_named?(_), do: false

  def enabled_badge(true), do: "badge-success"
  def enabled_badge(_), do: "badge-ghost"

  def enabled_label(true), do: gettext("Active")
  def enabled_label(false), do: "Inactivo"

  # A model_provider is effectively active only when ITS row is enabled AND
  # its credential exists and is in the "active" state. The credential
  # status is managed in /catalog/providers and must surface here too —
  # otherwise disabling the credential leaves a misleading "Activo" badge
  # in /catalog/models even though the router already filters the row out
  # of the candidate pool (router.ex filters by credential.status).
  @doc false
  def provider_active?(%{enabled: false}), do: false

  def provider_active?(%{credential: nil}), do: false

  def provider_active?(%{credential: %{status: status}}) when is_binary(status),
    do: status == "active"

  def provider_active?(_), do: true

  def credential_status_label(%{credential: %{status: "active"}}), do: nil
  def credential_status_label(%{credential: %{status: "disabled"}}), do: "credential desactivada"
  def credential_status_label(%{credential: nil}), do: gettext("no credential")
  def credential_status_label(_), do: nil

  # Toggle button title — what the click would do given the effective state.
  @doc false
  def toggle_title(%{enabled: false}), do: gettext("Enable")
  def toggle_title(ap), do: toggle_title_effective(ap)

  defp toggle_title_effective(ap) do
    if provider_active?(ap),
      do: gettext("Disable"),
      else: "Credential desactivada — activa en /catalog/providers"
  end

  def group_options(groups) do
    Enum.map(groups, fn t -> {t.name, t.id} end)
  end

  def member_options(members) do
    Enum.map(members, fn m ->
      label = if m.user, do: m.user.email, else: m.user_id
      {label, m.id}
    end)
  end

  @doc "All groups — the form filter is the search string in the template.
  See members_with_model_access/2 for the rationale."
  def groups_with_model_access(groups, _model_id), do: groups

  @doc "All members — the form filter is the search string in the template.
  The previous access check (GroupModel / GroupMemberExtraModel) only
  matters for the create flow; in the edit form we want every member to
  appear so the admin can re-pick even if grants have lapsed."
  def members_with_model_access(members, _model_id), do: members

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
          <:subtitle>{gettext("Configure models and their routing providers")}</:subtitle>
          <:actions :if={@is_admin}>
            <.button phx-click="new_model" id="new-model-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo Modelo
            </.button>
          </:actions>
        </.header>

        <%!-- Alias list --%>
        <%!-- The empty state must live OUTSIDE the stream container:
             phx-update="stream" only manages children keyed by stream ids,
             so a plain conditional div inside it never reaches the client. --%>
        <div
          :if={@models_empty?}
          id="models-empty"
          class="text-center py-12 text-base-content/40"
        >
          <.icon name="hero-cpu-chip" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>{empty_state_message()}</p>
        </div>

        <div id="models" phx-update="stream" class="space-y-3">
          <div :for={{id, model} <- @streams.models} id={id}>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-5">
                <div class="flex items-start justify-between gap-4">
                  <div
                    class="flex-1 min-w-0 cursor-pointer"
                    id={"model-header-#{model.id}"}
                    phx-click={toggle_providers_js(model.id)}
                    title={gettext("Expand / collapse providers")}
                  >
                    <div class="flex items-center gap-2 flex-wrap">
                      <span
                        id={"model-chevron-#{model.id}"}
                        class="text-base-content/40 transition-transform"
                      >
                        <.icon name="hero-chevron-right" class="w-4 h-4" />
                      </span>
                      <%!-- Same precedence as the modal: the linked lab's mark,
                           else the model's own icon, else the generic one. --%>
                      <.mark_badge
                        mark={Model.mark(model, @labs_by_key)}
                        id={"model-mark-#{model.id}"}
                      />
                      <h3 class="font-semibold text-base-content truncate">
                        {model.name}
                      </h3>
                      <span
                        class="text-xs text-base-content/40"
                        title={"#{model.context_window} tokens"}
                      >
                        · {format_compact(model.context_window)} ctx
                      </span>
                      <span
                        :if={model.model_type != "llm"}
                        class="badge badge-sm badge-outline badge-info"
                      >
                        {model.model_type}
                      </span>
                    </div>
                  </div>

                  <div class="flex gap-2 shrink-0">
                    <%= if @is_admin do %>
                      <button
                        phx-click="toggle_pin"
                        phx-value-id={model.id}
                        class="btn btn-sm btn-ghost"
                        id={"pin-model-#{model.id}"}
                        title={if model.pinned, do: gettext("Unpin"), else: gettext("Pin to top")}
                      >
                        <.icon
                          name={if model.pinned, do: "hero-star-solid", else: "hero-star"}
                          class={["w-4 h-4", model.pinned && "text-warning"]}
                        />
                      </button>
                      <button
                        phx-click="edit_guard_rails"
                        phx-value-id={model.id}
                        class="btn btn-sm btn-ghost"
                        id={"guard-rails-#{model.id}"}
                      >
                        <.icon name="hero-shield-check" class="w-4 h-4" /> Guard Rails
                      </button>
                      <button
                        phx-click="edit_model"
                        phx-value-id={model.id}
                        class="btn btn-sm btn-ghost"
                        id={"edit-model-#{model.id}"}
                      >
                        <.icon name="hero-pencil-square" class="w-4 h-4" /> Editar
                      </button>
                      <button
                        phx-click="delete_model"
                        phx-value-id={model.id}
                        data-confirm={gettext("Delete this model? This action cannot be undone.")}
                        class="btn btn-sm btn-ghost text-error"
                        id={"delete-model-#{model.id}"}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>

                <%!-- Alias providers list (inline) --%>
                <div
                  id={"model-providers-#{model.id}"}
                  class="mt-4 pt-4 border-t border-base-200"
                  style="display: none"
                >
                  <div class="flex items-center justify-between mb-2">
                    <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                      {gettext("Assigned providers")}
                    </h4>
                    <%= if @is_admin do %>
                      <button
                        phx-click="new_model_provider"
                        phx-value-model_id={model.id}
                        class="btn btn-xs btn-primary"
                        id={"new-ap-#{model.id}"}
                      >
                        <.icon name="hero-plus" class="w-3 h-3" /> Asignar Proveedor
                      </button>
                    <% end %>
                  </div>

                  <div
                    :if={model_providers_for(model) == []}
                    class="text-sm text-base-content/40 py-2"
                  >
                    {gettext("No providers assigned.")}
                  </div>

                  <div :if={model_providers_for(model) != []} class="overflow-x-auto">
                    <table class="table table-sm table-fixed w-full">
                      <thead>
                        <tr>
                          <th :if={@is_admin} class="w-8" title={gettext("Drag to reorder priority")}>
                          </th>
                          <th>{gettext("Provider")}</th>
                          <th>{gettext("Model")}</th>
                          <th>{gettext("Priority")}</th>
                          <th>{gettext("Scope")}</th>
                          <th>{gettext("Status")}</th>
                          <%= if @is_admin do %>
                            <th>{gettext("Actions")}</th>
                          <% end %>
                        </tr>
                      </thead>
                      <tbody
                        id={"ap-sortable-#{model.id}"}
                        phx-hook="SortableProviders"
                        data-model-id={model.id}
                      >
                        <% providers = model_providers_for(model) %>
                        <% groups = Enum.map(providers, &scope_group/1) %>
                        <% prev_groups = [nil | Enum.drop(groups, -1)] %>
                        <%= for {ap, prev_group} <- Enum.zip(providers, prev_groups) do %>
                          <% current_group = scope_group(ap) %>
                          <%!-- Group separator: a divider line + subtitle row when
                               the scope group changes (global → group → member). --%>
                          <%= if current_group != prev_group && not is_nil(scope_group_label(current_group)) do %>
                            <tr class="pointer-events-none border-t-2 border-base-300">
                              <td
                                colspan={if @is_admin, do: "7", else: "5"}
                                class="py-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/50"
                              >
                                {scope_group_label(current_group)}
                              </td>
                            </tr>
                          <% end %>
                          <tr
                            id={"model-provider-#{ap.id}"}
                            data-id={ap.id}
                            draggable={to_string(@is_admin)}
                            class={[@is_admin && "cursor-grab active:cursor-grabbing"]}
                          >
                            <td :if={@is_admin} class="w-8 text-base-content/30">
                              <.icon name="hero-bars-3" class="w-4 h-4" />
                            </td>
                            <td class="font-medium">
                              {provider_name(ap)}
                              <%!-- Credential name and key suffix expose internal
                                   topology — admins only. Non-admins see just the
                                   provider name. --%>
                              <span
                                :if={@is_admin && ap.credential && credential_named?(ap.credential)}
                                class="badge badge-xs badge-outline font-normal ml-1"
                                title={ap.credential.name}
                              >
                                <.icon name="hero-key" class="w-3 h-3" />
                                {ap.credential.name}
                              </span>
                              <span
                                :if={@is_admin && ap.credential}
                                class="text-xs text-base-content/40 ml-1"
                              >
                                {mask_key(ap.credential.api_key_encrypted)}
                              </span>
                            </td>
                            <td><code class="text-sm">{ap.provider_model}</code></td>
                            <td>
                              <span class="badge badge-xs badge-ghost">{ap.priority || "—"}</span>
                            </td>
                            <td>
                              <span class={["badge", "badge-sm", scope_badge(ap)]}>
                                {scope_label(ap)}
                              </span>
                              <%= if ap.exclusive_to_group_member_id || ap.exclusive_to_group_id do %>
                                <span class="text-xs text-base-content/40 ml-1">
                                  {scope_target_label(ap, assigns)}
                                </span>
                              <% end %>
                            </td>
                            <td>
                              <span
                                class={["badge", "badge-sm", enabled_badge(provider_active?(ap))]}
                                title={credential_status_label(ap)}
                              >
                                {enabled_label(provider_active?(ap))}
                              </span>
                            </td>
                            <%= if @is_admin do %>
                              <td>
                                <div class="flex gap-1">
                                  <button
                                    phx-click="toggle_model_provider"
                                    phx-value-id={ap.id}
                                    class="btn btn-xs btn-ghost"
                                    id={"toggle-ap-#{ap.id}"}
                                    title={toggle_title(ap)}
                                  >
                                    <.icon
                                      name={
                                        if provider_active?(ap), do: "hero-pause", else: "hero-play"
                                      }
                                      class="w-3 h-3"
                                    />
                                  </button>
                                  <button
                                    phx-click="edit_model_provider"
                                    phx-value-id={ap.id}
                                    class="btn btn-xs btn-ghost"
                                    id={"edit-ap-#{ap.id}"}
                                  >
                                    <.icon name="hero-pencil-square" class="w-3 h-3" />
                                  </button>
                                  <button
                                    phx-click="delete_model_provider"
                                    phx-value-id={ap.id}
                                    data-confirm={gettext("Remove this provider from the model?")}
                                    class="btn btn-xs btn-ghost text-error"
                                    id={"delete-ap-#{ap.id}"}
                                  >
                                    <.icon name="hero-trash" class="w-3 h-3" />
                                  </button>
                                </div>
                              </td>
                            <% end %>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            </div>
          </div>
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
                  "First choose the type — it decides the catalog filter, the providers offered, and the endpoint that will serve the model."
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

        <%!-- Alias form (new/edit) --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-4xl">
            <div class="card-body p-6 max-h-[88vh] overflow-y-auto">
              <h2 class="text-lg font-semibold mb-1">
                {if @editing_model_id == :new, do: gettext("New model"), else: gettext("Edit model")}
              </h2>

              <%!-- El wizard en 3 pasos, en el orden en que se decide todo:
                   proveedor (acotado por el tipo) → modelo → datos. El paso es un
                   assign porque el modal es el mismo; en edición se entra
                   directo a los datos (todo está ya decidido). --%>
              <div class="flex items-center gap-2 mb-4 text-xs" id="model-wizard-steps">
                <%= for {step, label} <- [{"provider", gettext("Provider")}, {"model", gettext("Model")}, {"details", gettext("Data")}] do %>
                  <span
                    id={"wizard-crumb-#{step}"}
                    class={[
                      "px-2 py-0.5 rounded-full border",
                      if(@wizard_step == step,
                        do: "border-primary bg-primary/10 text-primary font-medium",
                        else: "border-base-300 text-base-content/50"
                      )
                    ]}
                  >
                    {label}
                  </span>
                <% end %>
              </div>

              <%= if @wizard_step == "provider" do %>
                <p class="text-sm text-base-content/60 mb-3">
                  {gettext(
                    "Choose the provider that will serve this model. Only the providers that can serve the type you picked are listed."
                  )}
                </p>

                <input
                  type="text"
                  name="q"
                  id="wizard-provider-search"
                  value={@wizard_provider_search}
                  placeholder={gettext("Search provider… (e.g. openrouter, alibaba)")}
                  class="input input-sm w-full mb-2"
                  autocomplete="off"
                  phx-change="wizard_search_providers"
                  phx-debounce="150"
                />

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
                    phx-value-key={wizard_provider_ref(p)}
                    id={"wizard-provider-#{dom_key(wizard_provider_ref(p))}"}
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
                      phx-click="wizard_skip_provider"
                      class="btn btn-outline btn-sm"
                      id="wizard-all-models"
                    >
                      {gettext("See every model")}
                    </button>
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

              <%= if @wizard_step != "provider" do %>
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

                <%!-- Servicios de media: models.dev no los publica. La lista sale
                     del catálogo del proveedor — EN VIVO si publica catálogo por
                     servicio (`?output_modalities=…`), más la semilla verificada
                     como suelo. --%>
                <div
                  :if={@wizard_media_models != [] or @wizard_media_models_loading}
                  id="wizard-media-models"
                  class="mb-4"
                >
                  <p class="text-xs text-base-content/60 mb-2 flex items-center gap-2">
                    <span>
                      {gettext("Models this provider serves for this type:")}
                      <b id="wizard-media-count">{length(@wizard_media_models)}</b>
                    </span>
                    <span
                      :if={@wizard_media_models_loading}
                      class="flex items-center gap-1 text-base-content/50"
                      id="wizard-media-loading"
                    >
                      <span class="loading loading-spinner loading-xs"></span>
                      {gettext("loading the provider catalogue…")}
                    </span>
                  </p>
                  <div
                    :if={@wizard_media_models != []}
                    class="max-h-56 overflow-y-auto rounded-lg border border-base-300"
                  >
                    <button
                      :for={m <- @wizard_media_models}
                      type="button"
                      phx-click="wizard_pick_media_model"
                      phx-value-model={m}
                      id={"wizard-model-#{dom_key(m)}"}
                      class="block w-full text-left px-3 py-2 text-sm font-mono hover:bg-primary/10 transition-colors border-b border-base-300/60 last:border-0"
                    >
                      {m}
                    </button>
                  </div>
                </div>

                <%!-- Catalog picker: the SAME control in both modes, so an existing
                   model can be (re)linked exactly like a new one. Re-picking
                   overwrites name, context and prices — visible before Guardar,
                   which is what keeps it safe on a row already serving traffic. --%>
                <div class="flex gap-2 mb-4" id="model-form-tabs">
                  <button
                    type="button"
                    phx-click="set_model_tab"
                    phx-value-tab="catalog"
                    id="tab-catalog"
                    class={["btn btn-sm", @model_form_tab == "catalog" && "btn-primary"]}
                  >
                    <.icon name="hero-sparkles" class="w-4 h-4" /> {gettext("From catalog")}
                    <span class="badge badge-xs">{@catalog_type_count}</span>
                  </button>
                  <button
                    type="button"
                    phx-click="set_model_tab"
                    phx-value-tab="custom"
                    id="tab-custom"
                    class={["btn btn-sm", @model_form_tab == "custom" && "btn-primary"]}
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" /> Personalizado
                  </button>
                </div>

                <div :if={@model_form_tab == "catalog"} id="catalog-picker" class="mb-4">
                  <p class="text-xs text-base-content/60 mb-2">
                    {gettext("models.dev catalog:")} <b>{gettext("real metadata")}</b>
                    {gettext("(context, pricing, lab).")} {gettext(
                      "Picking one links the model to that entry and fills the form — nothing is"
                    )}
                    {gettext("saved until")} <b>{gettext("Save")}</b>{gettext(
                      ", and everything stays editable."
                    )}
                  </p>

                  <%!-- El buscador va dentro de su PROPIO form: sin un form ancestro
                     LiveView lanza «form events require the input to be inside a
                     form» y el phx-change nunca sale del navegador (los tests no
                     lo ven: despachan el evento directo al servidor). --%>
                  <form
                    id="catalog-search-form"
                    phx-change="search_catalog_models"
                    phx-submit="search_catalog_models"
                  >
                    <div class="relative">
                      <.icon
                        name="hero-magnifying-glass"
                        class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                      />
                      <input
                        type="text"
                        name="q"
                        id="catalog-search"
                        value={@catalog_query}
                        placeholder={
                          gettext("Search by name, id or lab… (e.g. gpt-5, glm, anthropic)")
                        }
                        class="input input-sm w-full pl-9"
                        autocomplete="off"
                        phx-change="search_catalog_models"
                        phx-debounce="150"
                      />
                    </div>
                  </form>

                  <div
                    :if={@catalog_results == [] and @catalog_query != ""}
                    id="catalog-empty"
                    class="text-sm text-base-content/50 py-4 text-center"
                  >
                    {gettext("No catalog model matches “%{query}”.", query: @catalog_query)}
                    {gettext("You can create it by hand in the")}
                    <b>{gettext("Custom")}</b> {gettext("tab.")}
                  </div>

                  <div
                    :if={@catalog_results == [] and @catalog_query == ""}
                    id="catalog-hint"
                    class="text-sm text-base-content/50 py-4 text-center"
                  >
                    {gettext("Type to search among the %{count} catalog models.",
                      count: @catalog_type_count
                    )}
                  </div>

                  <div
                    :if={@catalog_results != []}
                    id="catalog-results"
                    class="mt-2 max-h-72 overflow-y-auto rounded-lg border border-base-300"
                  >
                    <button
                      :for={entry <- @catalog_results}
                      type="button"
                      phx-click="pick_catalog_model"
                      phx-value-key={entry.key}
                      id={"catalog-row-#{dom_key(entry.key)}"}
                      class="w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/60 last:border-0 flex items-center gap-3"
                    >
                      <img
                        :if={lab_logo(@lab_logos, entry.lab_key)}
                        src={lab_logo(@lab_logos, entry.lab_key)}
                        alt=""
                        class="w-5 h-5 shrink-0 rounded"
                        loading="lazy"
                      />
                      <.icon
                        :if={!lab_logo(@lab_logos, entry.lab_key)}
                        name="hero-cpu-chip"
                        class="w-5 h-5 shrink-0 text-base-content/30"
                      />
                      <div class="min-w-0 flex-1">
                        <div class="flex items-center gap-2 flex-wrap">
                          <span class="font-medium text-sm truncate">{entry.name}</span>
                          <span
                            :if={catalog_taken?(@catalog_keys_taken, entry.key)}
                            class="badge badge-xs badge-warning"
                            title={gettext("A model created from this catalog entry already exists")}
                          >
                            {gettext("already exists")}
                          </span>
                          <span
                            :if={entry.provider_count == 0}
                            class="badge badge-xs badge-ghost"
                            title={
                              gettext(
                                "No supported provider serves it: it can be created, but there is nothing to route it to"
                              )
                            }
                          >
                            {gettext("no providers")}
                          </span>
                        </div>
                        <div class="text-xs text-base-content/50 font-mono truncate">{entry.key}</div>
                      </div>
                      <div class="text-right shrink-0">
                        <div class="text-xs tabular-nums text-base-content/70">
                          <%= if entry.context_limit do %>
                            {format_compact(entry.context_limit)} ctx
                          <% end %>
                        </div>
                        <div
                          :if={entry.cost_input || entry.cost_output}
                          class="text-xs tabular-nums text-base-content/50"
                        >
                          ${fmt_price(entry.cost_input)} / ${fmt_price(entry.cost_output)} per 1M
                        </div>
                        <div
                          :if={!entry.cost_input && !entry.cost_output}
                          class="text-xs text-base-content/40"
                        >
                          <span :if={entry.provider_count > 0}>
                            {entry.provider_count} proveedor(es)
                          </span>
                        </div>
                      </div>
                    </button>
                  </div>

                  <p
                    :if={@catalog_results != []}
                    class="text-[11px] text-base-content/40 mt-1"
                    id="catalog-count"
                  >
                    {gettext("Showing %{shown} of %{total} catalog models.",
                      shown: length(@catalog_results),
                      total: @catalog_type_count
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
                    phx-click="wizard_skip_model"
                    class="btn btn-outline btn-sm"
                    id="wizard-write-by-hand"
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Write it by hand")}
                  </button>
                </div>
              <% end %>

              <%!-- Catalog link: what the row was created from. Shown on edit too
                   (a model keeps its link), with the way out next to it. --%>
              <%= if Ecto.Changeset.get_field(@form.source, :catalog_model_key) do %>
                <% linked_key = Ecto.Changeset.get_field(@form.source, :catalog_model_key) %>
                <div
                  class="flex items-center gap-2 mb-3 px-3 py-2 rounded-lg bg-info/10 border border-info/30"
                  id="catalog-linked"
                >
                  <.icon name="hero-check-badge" class="w-4 h-4 text-info shrink-0" />
                  <span class="text-sm flex-1">
                    Vinculado a <code class="font-mono">{linked_key}</code>
                  </span>
                  <button
                    type="button"
                    phx-click="clear_catalog_pick"
                    class="btn btn-xs btn-ghost"
                    id="clear-catalog-pick"
                    title={gettext("Remove the catalog link")}
                  >
                    <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Remove link")}
                  </button>
                </div>
              <% end %>

              <%= if @wizard_step != "provider" do %>
                <%!-- Lo que el wizard ya decidió, y la API key que servirá el
                     modelo: es el input NECESARIO del alta — sin credencial no
                     hay lane, y sin lane el modelo no rutea. --%>
                <%= if @wizard_provider_key do %>
                  <div class="rounded-lg border border-base-300 p-3 mb-4" id="wizard-lane">
                    <div class="flex items-center gap-2 mb-2">
                      <.icon name="hero-server-stack" class="w-4 h-4 text-primary shrink-0" />
                      <span class="text-sm font-medium flex-1">
                        {wizard_lane_summary(@wizard_provider_label, @wizard_provider_model)}
                      </span>
                      <button
                        type="button"
                        phx-click="wizard_back"
                        phx-value-step="model"
                        class="btn btn-xs btn-ghost"
                        id="wizard-change-model"
                      >
                        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Change")}
                      </button>
                    </div>

                    <div class="grid md:grid-cols-2 gap-3">
                      <div class="fieldset mb-2">
                        <label class="label" for="wizard-credential">
                          {gettext("Credential (API key)")}
                        </label>
                        <select
                          id="wizard-credential"
                          name="credential_id"
                          class="select select-sm w-full"
                          phx-change="wizard_pick_credential"
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
                      </div>
                      <div class="fieldset mb-2">
                        <label class="label" for="wizard-provider-model">
                          {gettext("Provider model")}
                        </label>
                        <input
                          type="text"
                          id="wizard-provider-model"
                          name="wizard_provider_model"
                          value={@wizard_provider_model || ""}
                          class="input input-sm w-full"
                          phx-change="wizard_pick_provider_model"
                          phx-debounce="300"
                        />
                      </div>
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
                  <%!-- The catalog link travels with the form on submit: it is not
                     something the operator types, but it must reach the insert
                     or the row would be saved as a plain custom model. `lab_key`
                     needs no hidden twin: the lab select below owns it. --%>
                  <input
                    type="hidden"
                    name="model[catalog_model_key]"
                    value={Ecto.Changeset.get_field(@form.source, :catalog_model_key) || ""}
                  />
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
                          gettext(
                            "Defines which endpoint serves it (chat, embeddings, rerank, audio, image, video, music)."
                          )
                        }
                      />
                    </div>

                    <div class="space-y-1">
                      <.input
                        field={@form[:context_window]}
                        type="number"
                        label={gettext("Context window (tokens)")}
                        required
                        hint={gettext("Maximum context size of the model in tokens.")}
                      />

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
                          {gettext(
                            "The model's own icon is queued: it is used if you unlink the lab."
                          )}
                        </p>
                      <% else %>
                        <.input
                          field={@form[:icon]}
                          type="text"
                          label="Icono"
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
                      <% end %>
                    </div>
                  </div>

                  <div class="md:col-span-2 flex gap-2 mt-4 justify-end">
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
          </div>
        </div>

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

        <%!-- Alias provider form (new/edit) --%>
        <div :if={@provider_form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_model_provider" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-5xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_ap_id == :new,
                  do: gettext("Assign provider"),
                  else: gettext("Edit provider")}
              </h2>

              <.form
                for={@provider_form}
                id="model-provider-form"
                phx-submit="save_model_provider"
                phx-change="provider_form_changed"
                phx-window-keydown="close_scope_pickers"
                phx-key="Escape"
              >
                <%!-- Step 1 — the provider. When the model came from the catalog
                     this list is exactly the providers that serve it, cheapest
                     first; a custom model falls back to every active provider. --%>
                <div class="mb-5">
                  <label class="text-sm font-medium text-base-content">{gettext("Provider")}</label>
                  <p class="text-xs text-base-content/50 mb-2">
                    <%= if @editing_ap_id == :new do %>
                      {gettext("The provider of this row is")}
                      <b>{gettext("derived from the API key")}</b>
                      {gettext(
                        "you pick below: every credential belongs to a provider. If that provider serves this model according to"
                      )}
                      {gettext(
                        "models.dev, the provider model and the list price are filled in automatically."
                      )}
                      {gettext("You can also filter the API keys by provider here.")}
                    <% else %>
                      {gettext(
                        "Provider of this assignment, derived from its API key. Change the key below to"
                      )}
                      {gettext("move the row to another provider.")}
                    <% end %>
                  </p>

                  <%= if @provider_form_provider_key do %>
                    <div
                      class="flex items-center gap-2 px-3 py-2 rounded-lg bg-primary/10 border border-primary/30"
                      id="selected-provider"
                    >
                      <.icon name="hero-server-stack" class="w-4 h-4 text-primary shrink-0" />
                      <span class="text-sm font-medium flex-1">
                        {provider_chip_name(
                          @provider_choices,
                          @provider_credentials,
                          @provider_form_provider_key
                        )}
                        <span class="text-xs text-base-content/50 font-mono ml-1">
                          {@provider_form_provider_key}
                        </span>
                      </span>
                      <button
                        type="button"
                        phx-click="clear_provider_choice"
                        class="btn btn-xs btn-ghost"
                        id="change-provider"
                        title={gettext("Choose another provider")}
                      >
                        <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Change")}
                      </button>
                    </div>
                  <% else %>
                    <%!-- A bare input, NOT wrapped in a form: this picker lives
                       inside #model-provider-form, and a form inside a form is
                       dropped by HTML parsers (which would cut the outer form in
                       two and orphan every field after it). --%>
                    <div class="relative">
                      <.icon
                        name="hero-magnifying-glass"
                        class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                      />
                      <input
                        type="text"
                        name="q"
                        id="provider-search"
                        value={@provider_search}
                        placeholder={
                          gettext("Search provider by name or id… (e.g. openrouter, fireworks)")
                        }
                        class="input input-sm w-full pl-9"
                        autocomplete="off"
                        phx-change="search_providers"
                        phx-debounce="150"
                      />
                    </div>

                    <div
                      :if={@provider_choices_results == []}
                      id="provider-empty"
                      class="text-sm text-base-content/50 py-3 text-center"
                    >
                      {gettext("No provider matches. Create the provider in")}
                      <b>/catalog/providers</b>
                      {gettext("and come back here.")}
                    </div>

                    <div
                      :if={@provider_choices_results != []}
                      id="provider-results"
                      class="mt-2 max-h-56 overflow-y-auto rounded-lg border border-base-300"
                    >
                      <button
                        :for={choice <- @provider_choices_results}
                        type="button"
                        phx-click="select_provider"
                        phx-value-key={choice.provider.key}
                        id={"provider-row-#{dom_key(choice.provider.key)}"}
                        class="w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/60 last:border-0 flex items-center gap-2"
                      >
                        <img
                          :if={choice.provider.logo_url}
                          src={choice.provider.logo_url}
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
                          class={[
                            "w-5 h-5 shrink-0 text-base-content/30",
                            choice.provider.logo_url && "hidden"
                          ]}
                        />
                        <span class="flex-1 min-w-0">
                          <span class="text-sm font-medium truncate">{choice.provider.name}</span>
                          <span class="text-xs text-base-content/50 font-mono ml-1">
                            {choice.provider.key}
                          </span>
                        </span>
                        <span
                          :if={choice.offer && (choice.offer.cost_input || choice.offer.cost_output)}
                          class="text-xs tabular-nums text-base-content/60 shrink-0"
                        >
                          ${fmt_price(choice.offer.cost_input)} / ${fmt_price(
                            choice.offer.cost_output
                          )}
                        </span>
                        <span
                          :if={length(choice.provider.credentials) > 0}
                          class="badge badge-xs badge-success shrink-0"
                          title="Ya tiene API keys dadas de alta"
                        >
                          {length(choice.provider.credentials)} key(s)
                        </span>
                        <span
                          :if={length(choice.provider.credentials) == 0}
                          class="badge badge-xs badge-ghost shrink-0"
                        >
                          {gettext("no key")}
                        </span>
                      </button>
                    </div>

                    <p
                      :if={@provider_choices_results != []}
                      class="text-[11px] text-base-content/40 mt-1"
                    >
                      Mostrando {length(@provider_choices_results)} de {length(@provider_choices)} proveedores para este modelo.
                    </p>
                  <% end %>
                </div>

                <div class="grid md:grid-cols-2 gap-x-8 gap-y-5">
                  <div>
                    <div class="flex items-end gap-2">
                      <div class="flex-1">
                        <.input
                          field={@provider_form[:credential_id]}
                          type="select"
                          label={gettext("Credential (API key)")}
                          options={credential_options(@credential_choices)}
                          prompt={
                            cond do
                              @credential_choices == [] ->
                                gettext("No active API keys")

                              @provider_form_provider_key ->
                                gettext("Pick an API key from this provider")

                              true ->
                                gettext("Pick the API key that will serve this model")
                            end
                          }
                          required
                          hint={
                            gettext(
                              "The specific API key that will serve this model. Picking it derives its provider, and with it the provider model and the list price when models.dev publishes them. Every credential has its own circuit breaker and priority."
                            )
                          }
                        />
                      </div>
                      <button
                        type="button"
                        phx-click="new_credential_inline"
                        class="btn btn-sm btn-outline mb-6"
                        id="new-credential-inline"
                        title={gettext("Add another API key for this provider")}
                      >
                        <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New API key")}
                      </button>
                    </div>

                    <div
                      :if={!is_nil(@provider_form_provider_key) and @credential_choices == []}
                      class="text-xs text-warning -mt-3 mb-2"
                      id="no-credentials-hint"
                    >
                      {gettext(
                        "This provider has no API keys yet. Use “New API key” to create the first one."
                      )}
                    </div>

                    <%= if @provider_models_loading do %>
                      <div class="flex items-center gap-2 text-sm text-base-content/50 py-2">
                        <span class="loading loading-spinner loading-xs"></span>
                        {gettext("Loading provider models…")}
                      </div>
                    <% end %>

                    <.input
                      field={@provider_form[:provider_model]}
                      type="text"
                      label={gettext("Provider model")}
                      required
                      placeholder={gettext("Type or pick the model (e.g. glm-5.2:dedicated)")}
                      hint={
                        gettext(
                          "Suggestions from the provider catalog. You can type any value for dedicated or private tiers."
                        )
                      }
                    />
                    <%= if @provider_models != [] and !@provider_models_loading do %>
                      <% search = String.downcase(@provider_model_search || "") %>
                      <% filtered =
                        Enum.filter(@provider_models, fn m ->
                          String.contains?(String.downcase(m), search)
                        end) %>
                      <%= if filtered != [] do %>
                        <div class="mt-1 max-h-32 overflow-y-auto rounded-lg border border-base-300 bg-base-200/50">
                          <button
                            :for={model <- filtered}
                            type="button"
                            phx-click="select_provider_model"
                            phx-value-model={model}
                            class="block w-full text-left px-3 py-1.5 text-sm font-mono hover:bg-primary/10 transition-colors border-b border-base-300/50 last:border-0"
                          >
                            {model}
                          </button>
                        </div>
                      <% end %>
                    <% end %>
                  </div>

                  <div class="space-y-1">
                    <%!-- Scope selector --%>
                    <div class="mb-2">
                      <label class="text-sm font-medium text-base-content">{gettext("Scope")}</label>
                      <p class="text-xs text-base-content/50 mb-2">
                        {gettext(
                          "Global = every member with access. Exclusive = only the selected member or limit profile."
                        )}
                      </p>
                      <div class="flex gap-2">
                        <button
                          type="button"
                          phx-click="change_scope"
                          phx-value-scope="global"
                          class={["btn btn-sm", @current_scope == "global" && "btn-primary"]}
                        >
                          <.icon name="hero-globe-alt" class="w-4 h-4" /> Global
                        </button>
                        <button
                          type="button"
                          phx-click="change_scope"
                          phx-value-scope="group"
                          class={["btn btn-sm", @current_scope == "group" && "btn-info"]}
                        >
                          <.icon name="hero-users" class="w-4 h-4" /> {gettext("Limit profile")}
                        </button>
                        <button
                          type="button"
                          phx-click="change_scope"
                          phx-value-scope="member"
                          class={["btn btn-sm", @current_scope == "member" && "btn-warning"]}
                        >
                          <.icon name="hero-user" class="w-4 h-4" /> Usuario
                        </button>
                      </div>
                    </div>

                    <%= if @current_scope == "member" do %>
                      <% is_new? = @editing_ap_id == :new %>
                      <div class="relative" phx-click-away="close_scope_pickers">
                        <label class="text-sm font-medium text-base-content">{gettext(
                          "Exclusive user"
                        )}</label>
                        <p class="text-xs text-base-content/50 mb-1">
                          <%= if is_new? do %>
                            {gettext(
                              "You can select multiple users. An exclusive provider will be created for each one."
                            )}
                          <% else %>
                            {gettext(
                              "Only this user will be able to use this API key for this model."
                            )}
                          <% end %>
                        </p>
                        <%= if is_new? do %>
                          <%!-- Multi-select chips for create mode --%>
                          <% members_filtered =
                            members_with_model_access(@members_for_select, @provider_form_model_id)
                            |> Enum.filter(fn m ->
                              search = String.downcase(@scope_member_search || "")
                              email = if m.user, do: String.downcase(m.user.email), else: ""

                              name =
                                if m.user && m.user.name, do: String.downcase(m.user.name), else: ""

                              search == "" or String.contains?(email, search) or
                                String.contains?(name, search)
                            end) %>
                          <input
                            type="text"
                            name="model_provider[scope_member_id_display]"
                            value={@scope_member_search}
                            placeholder={gettext("Type to search a user…")}
                            phx-focus="open_scope_picker"
                            phx-value-picker="member"
                            phx-change="scope_member_search"
                            phx-debounce="200"
                            class="input input-sm w-full"
                            autocomplete="off"
                          />
                          <%= if @scope_member_open and members_filtered != [] do %>
                            <div class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-40 overflow-y-auto">
                              <button
                                :for={m <- Enum.take(members_filtered, 15)}
                                type="button"
                                phx-click="toggle_scope_member"
                                phx-value-member_id={m.id}
                                class={[
                                  "block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/50 last:border-0",
                                  m.id in (@current_scope_member_ids || []) &&
                                    "bg-primary/10 font-semibold"
                                ]}
                              >
                                <span class="text-sm font-medium">{m.user.email}</span>
                                <span :if={m.user.name} class="text-xs text-base-content/50 ml-1">({m.user.name})</span>
                                <span
                                  :if={m.id in (@current_scope_member_ids || [])}
                                  class="text-xs text-primary ml-2"
                                >
                                  ✓
                                </span>
                              </button>
                            </div>
                          <% end %>
                          <%!-- Selected chips --%>
                          <div :if={@current_scope_member_ids != []} class="flex flex-wrap gap-1 mt-2">
                            <span
                              :for={mid <- @current_scope_member_ids}
                              class="badge badge-warning badge-sm gap-1 cursor-pointer"
                              phx-click="toggle_scope_member"
                              phx-value-member_id={mid}
                            >
                              {case Enum.find(@members_for_select || [], &(&1.id == mid)) do
                                %{user: %{email: e}} -> e
                                _ -> mid
                              end}
                              <.icon name="hero-x-mark" class="w-3 h-3" />
                            </span>
                          </div>
                        <% else %>
                          <%!-- Single-select for edit mode --%>
                          <input
                            type="text"
                            name="model_provider[scope_member_id_display]"
                            value={@scope_member_search}
                            placeholder={gettext("Type to search a user…")}
                            phx-focus="open_scope_picker"
                            phx-value-picker="member"
                            phx-change="scope_member_search"
                            phx-debounce="200"
                            class="input input-sm w-full"
                            autocomplete="off"
                          />
                          <% members_filtered =
                            members_with_model_access(@members_for_select, @provider_form_model_id)
                            |> Enum.filter(fn m ->
                              search = String.downcase(@scope_member_search || "")
                              email = if m.user, do: String.downcase(m.user.email), else: ""

                              name =
                                if m.user && m.user.name, do: String.downcase(m.user.name), else: ""

                              search == "" or String.contains?(email, search) or
                                String.contains?(name, search)
                            end) %>
                          <%= if @scope_member_open and members_filtered != [] do %>
                            <div class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-40 overflow-y-auto">
                              <button
                                :for={m <- Enum.take(members_filtered, 10)}
                                type="button"
                                phx-click="select_scope_member_item"
                                phx-value-member_id={m.id}
                                phx-value-member_label={if(m.user, do: m.user.email, else: m.id)}
                                class={[
                                  "block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/50 last:border-0",
                                  m.id == @current_scope_member_id && "bg-primary/10 font-semibold"
                                ]}
                              >
                                <span class="text-sm font-medium">{m.user.email}</span>
                                <span :if={m.user.name} class="text-xs text-base-content/50 ml-1">({m.user.name})</span>
                                <span
                                  :if={m.id == @current_scope_member_id}
                                  class="text-xs text-primary ml-2"
                                >
                                  {gettext("(current)")}
                                </span>
                              </button>
                            </div>
                          <% end %>
                          <input
                            type="hidden"
                            name="model_provider[scope_member_id]"
                            value={@current_scope_member_id}
                          />
                        <% end %>
                      </div>
                    <% end %>

                    <%= if @current_scope == "group" do %>
                      <% is_new? = @editing_ap_id == :new %>
                      <div class="relative" phx-click-away="close_scope_pickers">
                        <label class="text-sm font-medium text-base-content">{gettext(
                          "Exclusive limit profile"
                        )}</label>
                        <p class="text-xs text-base-content/50 mb-1">
                          <%= if is_new? do %>
                            {gettext(
                              "You can select multiple limit profiles. An exclusive provider will be created for each one."
                            )}
                          <% else %>
                            {gettext(
                              "Only the members of this limit profile will be able to use this API key for this model."
                            )}
                          <% end %>
                        </p>
                        <%= if is_new? do %>
                          <%!-- Multi-select chips for create mode --%>
                          <% groups_filtered =
                            groups_with_model_access(@groups_for_select, @provider_form_model_id)
                            |> Enum.filter(fn t ->
                              search = String.downcase(@scope_group_search || "")
                              name = String.downcase(t.name || "")
                              search == "" or String.contains?(name, search)
                            end) %>
                          <input
                            type="text"
                            name="model_provider[scope_group_id_display]"
                            value={@scope_group_search}
                            placeholder={gettext("Type to search a limit profile…")}
                            phx-focus="open_scope_picker"
                            phx-value-picker="group"
                            phx-change="scope_group_search"
                            phx-debounce="200"
                            class="input input-sm w-full"
                            autocomplete="off"
                          />
                          <%= if @scope_group_open and groups_filtered != [] do %>
                            <div class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-40 overflow-y-auto">
                              <button
                                :for={t <- Enum.take(groups_filtered, 15)}
                                type="button"
                                phx-click="toggle_scope_group"
                                phx-value-group_id={t.id}
                                class={[
                                  "block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/50 last:border-0",
                                  t.id in (@current_scope_group_ids || []) &&
                                    "bg-primary/10 font-semibold"
                                ]}
                              >
                                <span class="text-sm font-medium">{t.name}</span>
                                <span
                                  :if={t.id in (@current_scope_group_ids || [])}
                                  class="text-xs text-primary ml-2"
                                >
                                  ✓
                                </span>
                              </button>
                            </div>
                          <% end %>
                          <%!-- Selected chips --%>
                          <div :if={@current_scope_group_ids != []} class="flex flex-wrap gap-1 mt-2">
                            <span
                              :for={tid <- @current_scope_group_ids}
                              class="badge badge-info badge-sm gap-1 cursor-pointer"
                              phx-click="toggle_scope_group"
                              phx-value-group_id={tid}
                            >
                              {case Enum.find(@groups_for_select || [], &(&1.id == tid)) do
                                %{name: n} -> n
                                _ -> tid
                              end}
                              <.icon name="hero-x-mark" class="w-3 h-3" />
                            </span>
                          </div>
                        <% else %>
                          <%!-- Single-select for edit mode --%>
                          <input
                            type="text"
                            name="model_provider[scope_group_id_display]"
                            value={@scope_group_search}
                            placeholder={gettext("Type to search a limit profile…")}
                            phx-focus="open_scope_picker"
                            phx-value-picker="group"
                            phx-change="scope_group_search"
                            phx-debounce="200"
                            class="input input-sm w-full"
                            autocomplete="off"
                          />
                          <% groups_filtered =
                            groups_with_model_access(@groups_for_select, @provider_form_model_id)
                            |> Enum.filter(fn t ->
                              search = String.downcase(@scope_group_search || "")
                              name = String.downcase(t.name || "")
                              search == "" or String.contains?(name, search)
                            end) %>
                          <%= if @scope_group_open and groups_filtered != [] do %>
                            <div class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-40 overflow-y-auto">
                              <button
                                :for={t <- Enum.take(groups_filtered, 10)}
                                type="button"
                                phx-click="select_scope_group_item"
                                phx-value-group_id={t.id}
                                phx-value-group_label={t.name}
                                class={[
                                  "block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/50 last:border-0",
                                  t.id == @current_scope_group_id && "bg-primary/10 font-semibold"
                                ]}
                              >
                                <span class="text-sm font-medium">{t.name}</span>
                                <span
                                  :if={t.id == @current_scope_group_id}
                                  class="text-xs text-primary ml-2"
                                >
                                  {gettext("(current)")}
                                </span>
                              </button>
                            </div>
                          <% end %>
                          <input
                            type="hidden"
                            name="model_provider[scope_group_id]"
                            value={@current_scope_group_id}
                          />
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <div class="md:col-span-2">
                    <div class="grid grid-cols-2 gap-3">
                      <.input
                        field={@provider_form[:priority]}
                        type="number"
                        label="Prioridad"
                        hint="Menor = se intenta primero."
                      />
                      <.input
                        field={@provider_form[:sticky_ttl_seconds]}
                        type="number"
                        label="TTL sticky (segundos)"
                        hint={
                          gettext(
                            "Empty uses the config default (180 s / 3 min) for every credential, regardless of billing. If you set a value, that one is always used. Minimum 1 s, maximum 86400 s (24 h). It is stored in milliseconds."
                          )
                        }
                      />
                    </div>

                    <%!-- El precio se cobra en la unidad que ESTE lane declara. Los
                         tres campos de token sólo tienen sentido cuando la unidad es de
                         tokens; un lane de imagen/tts/stt se cobra por unidad, y sin ese
                         campo quedaba en $0 salvo que el upstream reportara el coste. --%>
                    <div class="grid grid-cols-2 gap-3">
                      <%!-- Select propio (no `<.input>`) porque necesita su PROPIO
                           phx-change: es lo que conmuta los campos de abajo sin
                           revalidar el form entero (los errores de validación de
                           un form a medio llenar serían ruido). --%>
                      <div class="fieldset mb-2">
                        <label class="label" for="ap-pricing-unit">{gettext("Pricing unit")}</label>
                        <select
                          id="ap-pricing-unit"
                          name="model_provider[pricing_unit]"
                          class="select w-full"
                          phx-change="pick_pricing_unit"
                        >
                          <option
                            :for={{label, key} <- pricing_unit_options(@provider_form_model_id)}
                            value={key}
                            selected={@provider_form_pricing_unit == key}
                          >
                            {label}
                          </option>
                        </select>
                        <p class="text-xs text-base-content/50 mt-1">
                          {gettext(
                            "What this provider charges per. It defaults to the model's own unit; change it if this provider prices differently."
                          )}
                        </p>
                      </div>
                      <%= if not token_priced?(@provider_form_pricing_unit) do %>
                        <.input
                          field={@provider_form[:unit_cost]}
                          type="number"
                          step="0.000001"
                          min="0"
                          label={gettext("Unit cost (USD per unit)")}
                          hint={
                            gettext(
                              "Fallback when the provider does not report cost. It is multiplied by what the call actually produced (images, megapixels, seconds, characters)."
                            )
                          }
                        />
                      <% end %>
                    </div>

                    <%= if token_priced?(@provider_form_pricing_unit) do %>
                      <div class="grid grid-cols-3 gap-3">
                        <.input
                          field={@provider_form[:input_cost_per_million]}
                          type="number"
                          step="0.000001"
                          min="0"
                          label={gettext("Input cost (USD / 1M)")}
                          hint={
                            gettext(
                              "Non-cached input tokens. Fallback when the provider does not report cost."
                            )
                          }
                        />
                        <.input
                          field={@provider_form[:cache_cost_per_million]}
                          type="number"
                          step="0.000001"
                          min="0"
                          label={gettext("Cache cost (USD / 1M)")}
                          hint={
                            gettext(
                              "Input tokens with a cache hit (cheaper). Empty = use the input price for all of them."
                            )
                          }
                        />
                        <.input
                          field={@provider_form[:output_cost_per_million]}
                          type="number"
                          step="0.000001"
                          min="0"
                          label={gettext("Output cost (USD / 1M)")}
                          hint={gettext("Output tokens. Same fallback as input.")}
                        />
                      </div>
                    <% end %>

                    <%= if @provider_form_is_fireworks do %>
                      <.input
                        field={@provider_form[:service_tier_priority]}
                        type="checkbox"
                        label="Fireworks Priority (service_tier)"
                        hint={
                          gettext(
                            "Sends service_tier: priority — more reliability at peak hours, billed at a premium depending on the model."
                          )
                        }
                      />
                      <p class="text-xs text-base-content/50 -mt-2">
                        <.icon name="hero-bolt" class="w-3.5 h-3.5 inline text-success" />
                        {gettext("Prompt cache:")} <b>{gettext("on by default")}</b>
                        {gettext(
                          "on Fireworks (prefix matching, cached tokens at a discount). TokenGate keeps conversations sticky via the x-session-affinity header and logs the cached tokens — no configuration required."
                        )}
                      </p>
                    <% end %>

                    <.input
                      field={@provider_form[:enabled]}
                      type="checkbox"
                      label="Habilitado"
                      hint={gettext("If it is off, this provider gets no traffic for the model.")}
                    />
                  </div>
                </div>

                <div class="md:col-span-2 flex gap-2 pt-4 mt-5 border-t border-base-200 justify-end">
                  <button type="button" phx-click="cancel_model_provider" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-ap-btn">
                    {gettext("Save")}
                  </button>
                </div>
              </.form>

              <%!-- Inline API-key form. It is a SIBLING of the model_provider
                   form, never nested (a form inside a form is dropped by the
                   browser and the key could never be submitted). Creating the key
                   here leaves it selected, so the model is one click from
                   routable. --%>
              <%= if @credential_form do %>
                <div
                  class="mt-5 p-4 rounded-lg border border-primary/40 bg-primary/5"
                  id="inline-credential-form"
                >
                  <h3 class="text-sm font-semibold mb-1">
                    Nueva API key
                    <%= if @provider_form_provider_key do %>
                      <span class="text-xs font-normal text-base-content/60">
                        para {provider_label(@provider_choices, @provider_form_provider_key)}
                      </span>
                    <% end %>
                  </h3>

                  <.form
                    for={@credential_form}
                    id="inline-credential"
                    phx-submit="save_new_credential"
                  >
                    <div class="grid sm:grid-cols-2 gap-x-4 gap-y-3">
                      <.input
                        field={@credential_form[:name]}
                        type="text"
                        label="Alias"
                        placeholder={gettext("Production")}
                        hint={gettext("Name to identify this credential.")}
                      />
                      <.input
                        field={@credential_form[:api_key_encrypted]}
                        type="password"
                        label="API key"
                        placeholder="sk-..."
                        hint={gettext("The token the provider gives you.")}
                      />
                    </div>
                    <div class="flex gap-2 mt-3 justify-end">
                      <button
                        type="button"
                        phx-click="cancel_new_credential"
                        class="btn btn-ghost btn-xs"
                      >
                        {gettext("Cancel")}
                      </button>
                      <button
                        type="submit"
                        class="btn btn-primary btn-xs"
                        id="save-inline-credential-btn"
                      >
                        {gettext("Create and use")}
                      </button>
                    </div>
                  </.form>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
