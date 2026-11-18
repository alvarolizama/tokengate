defmodule TokengateWeb.ModelProvidersLive do
  @moduledoc """
  Los LANES de un modelo — `/catalog/models/:id`.

  Un lane (`model_providers`) es "esta API key sirve a este modelo con este
  nombre en el upstream, a este precio y para este alcance". El listado
  (`TokengateWeb.ModelsLive`) muestra una fila por modelo; aquí vive lo que
  hace que el modelo sea ruteable: asignar una key, darle prioridad, acotarla
  a un perfil de límites / usuario / servicio, ponerle precio y ordenar el
  fallback.

  El precio y la unidad son DEL LANE, no del modelo: dos proveedores del mismo
  modelo pueden cobrar distinto y en unidades distintas
  (`model_providers.pricing_unit`).
  """

  use TokengateWeb, :live_view

  @provider_results_limit 8

  # Campos por paso del wizard del lane: si el save falla con un campo que vive
  # en un paso oculto, el modal salta al paso dueño del error (si no, el aviso
  # se quedaría fuera de pantalla).
  @credential_fields [:model_id, :credential_id, :pool_id, :provider_model]

  @routing_fields [
    :enabled,
    :priority,
    :sticky_ttl_ms,
    :sticky_ttl_seconds,
    :exclusive_to_group_id,
    :exclusive_to_group_member_id
  ]

  @pricing_fields [
    :pricing_unit,
    :unit_cost,
    :input_cost_per_million,
    :output_cost_per_million,
    :cache_cost_per_million,
    :cache_write_cost_per_million
  ]

  import Ecto.Query, only: [from: 2]
  import TokengateWeb.ModelPicker

  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Credential,
    CredentialPool,
    CredentialPoolMember,
    Model,
    ModelProvider,
    Pricing,
    Provider
  }

  alias Tokengate.Repo

  @impl true
  def mount(%{"id" => model_id} = params, _session, socket) do
    case fetch_model(model_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Model not found."))
         |> redirect(to: ~p"/catalog/models")}

      model ->
        user = socket.assigns[:current_user]

        socket =
          socket
          |> assign(:page_title, model.name <> " · Tokengate")
          |> assign(:model, model)
          |> assign(:is_admin, user && user.global_role == "admin")
          |> assign(:provider_form, nil)
          |> assign(:editing_ap_id, nil)
          |> assign(:credential_form, nil)
          # Paso del wizard del modal (credential → routing → pricing). El modal
          # lo gatea `provider_form`; en reposo se queda en el primero.
          |> assign(:lane_step, "credential")
          |> assign(:lane_step_error, nil)
          # Estado del modal de lane en reposo: la página tiene que renderizar
          # (y los tests leer el socket) antes de que se abra cualquier form.
          |> assign(:provider_form_model_id, nil)
          |> assign(:provider_form_provider_key, nil)
          |> assign(:provider_form_credential_id, nil)
          |> assign(:provider_form_is_fireworks, false)
          |> assign(:provider_form_pricing_unit, nil)
          # Fuente del lane: una key (`"key"`) o un pool (`"pool"`). El modal
          # abre siempre en el camino de siempre; el pool es un opt-in.
          |> assign(:lane_source, "key")
          |> assign(:lane_pool_id, nil)
          |> assign(:lane_pool_error, nil)
          |> assign(:lane_new_pool_open, false)
          |> assign(:provider_pools, [])
          |> assign(:expanded_pools, MapSet.new())
          |> assign(:provider_credentials, nil)
          |> assign(:provider_models, [])
          |> assign(:provider_models_loading, false)
          |> assign(:provider_model_search, "")
          |> assign(:provider_choices, [])
          |> assign(:provider_choices_results, [])
          |> assign(:provider_search, "")
          |> assign(:credential_choices, [])
          |> assign(:current_scope, "global")
          |> assign(:current_scope_group_id, nil)
          |> assign(:current_scope_member_id, nil)
          |> assign(:current_scope_group_ids, [])
          |> assign(:current_scope_member_ids, [])
          |> assign(:scope_group_search, "")
          |> assign(:scope_member_search, "")
          |> assign(:scope_group_open, false)
          |> assign(:scope_member_open, false)
          |> require_admin_hook()
          |> assign_form_data()
          |> assign_scope_data()
          |> load_lanes()
          |> open_requested_form(params)

        {:ok, socket}
    end
  end

  # `Repo.get/2` raises on an id that is not a UUID: a hand-typed URL must land
  # on the list, not crash the mount.
  defp fetch_model(model_id) do
    Providers.get_model(model_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  # The catalog is the only source of VALID model ids: cast first (an id that is
  # not even a UUID never reaches Repo) and then a real row. Every event that
  # takes a `model_id` from the client goes through here.
  defp fetch_catalog_model(model_id) do
    with {:ok, id} <- Ecto.UUID.cast(model_id),
         %Model{} = model <- Providers.get_model(id) do
      {:ok, model}
    else
      _ -> :error
    end
  end

  # A lane addressed by a client id is only usable when it exists AND belongs to
  # the model of this page: editing or deleting another model's lane from here
  # would be a cross-model write triggered by a forged payload.
  defp fetch_lane(socket, ap_id) do
    with {:ok, id} <- Ecto.UUID.cast(ap_id),
         %ModelProvider{model_id: model_id} = ap <- Providers.get_model_provider(id),
         true <- model_id == socket.assigns.model.id do
      ap
    else
      _ -> nil
    end
  end

  # `?edit=<ap_id>` viene del "Change" del modal del modelo (el índice ya no
  # edita lanes en línea) y `?new=1` de cualquier enlace que quiera el alta
  # abierta. Cualquier otro id es un no-op.
  defp open_requested_form(socket, %{"new" => "1"}), do: open_new_lane(socket)
  defp open_requested_form(socket, %{"edit" => ap_id}), do: open_lane(socket, ap_id)
  defp open_requested_form(socket, _params), do: socket

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a client can fire events straight over the socket.
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

  # Los lanes se ordenan igual que los leía el índice: global primero, luego
  # por perfil de límites y por usuario, con `priority` dentro de cada grupo.
  defp load_lanes(socket) do
    model = socket.assigns.model

    lanes =
      from(ap in ModelProvider,
        where: ap.model_id == ^model.id,
        # El pool entra en el MISMO preload (una query batcheada por asociación):
        # la fila del lane necesita su nombre, su conteo de keys y sus miembros,
        # y una query por fila sería un N+1 en cada render y en cada load_lanes.
        preload: [credential: :provider, pool: [members: [credential: :provider]]],
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN 2 WHEN ? IS NOT NULL THEN 1 ELSE 0 END",
              ap.exclusive_to_group_member_id,
              ap.exclusive_to_group_id
            ),
          asc_nulls_last: ap.priority
        ]
      )
      |> Repo.all()

    socket
    |> assign(:model_providers, lanes)
    |> assign(:lane_scope_headers, lane_scope_headers(lanes))
  end

  # Rótulo del bloque de scope (global → perfil de límites → usuario). `.table`
  # dibuja un `<tr>` por lane y no tiene filas separadoras ni colspan, así que
  # la etiqueta viaja en la PRIMERA celda del primer lane de cada grupo. El
  # grupo global no lleva rótulo (`scope_group_label/1` devuelve nil).
  defp lane_scope_headers(lanes) do
    {_prev, headers} =
      Enum.reduce(lanes, {nil, %{}}, fn ap, {prev, acc} ->
        group = scope_group(ap)

        cond do
          is_nil(scope_group_label(group)) -> {group, acc}
          group == prev -> {group, acc}
          true -> {group, Map.put(acc, ap.id, scope_group_label(group))}
        end
      end)

    headers
  end

  defp open_new_lane(socket) do
    model = socket.assigns.model
    unit = Pricing.default_unit_for_type(model.model_type || "llm")

    changeset =
      Providers.change_model_provider(%ModelProvider{
        model_id: model.id,
        enabled: true,
        pricing_unit: unit
      })

    socket
    |> assign(:provider_form_model_id, model.id)
    |> assign(:provider_form, to_form(changeset, as: :model_provider))
    |> assign(:editing_ap_id, :new)
    |> assign(:lane_step, "credential")
    |> assign(:lane_step_error, nil)
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
    |> assign(:provider_models_loading, false)
    |> assign(:provider_model_search, "")
    |> build_provider_choices(model.id)
    |> assign(:provider_credentials, nil)
    |> reset_lane_source()
    |> assign_credential_choices()
  end

  defp open_lane(socket, ap_id) do
    socket
    |> assign(:provider_form_model_id, socket.assigns.model.id)
    |> open_lane_modal(ap_id)
  end

  @impl true
  ## Events — model_provider management -------------------------------------

  def handle_event("new_model_provider", %{"model_id" => model_id}, socket) do
    cond do
      not socket.assigns.is_admin ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      true ->
        case fetch_catalog_model(model_id) do
          {:ok, model} ->
            # La unidad de precio nace con la del TIPO del modelo: un lane de
            # imagen abre en «por imagen» y uno de voz en «por 1k caracteres»,
            # no en tokens. El operador la cambia si su proveedor cobra
            # distinto.
            unit = Pricing.default_unit_for_type(model.model_type || "llm")

            changeset =
              Providers.change_model_provider(%ModelProvider{
                model_id: model.id,
                enabled: true,
                pricing_unit: unit
              })

            {:noreply,
             socket
             |> assign(:provider_form_model_id, model.id)
             |> assign(:provider_form, to_form(changeset, as: :model_provider))
             |> assign(:editing_ap_id, :new)
             |> assign(:lane_step, "credential")
             |> assign(:lane_step_error, nil)
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
             # A fresh modal has no fetch in flight: the flag of the previous
             # session otherwise shows a spinner (and hides the suggestions)
             # forever.
             |> assign(:provider_models_loading, false)
             |> assign(:provider_model_search, "")
             |> build_provider_choices(model.id)
             |> assign(:provider_credentials, nil)
             |> reset_lane_source()
             |> assign_credential_choices()}

          # Id forjado o de un modelo que no está en el catálogo: no se abre
          # ningún form (el lane nacería apuntando a la nada).
          :error ->
            {:noreply, put_flash(socket, :error, gettext("Model not found."))}
        end
    end
  end

  def handle_event("new_model_provider", _params, socket), do: {:noreply, socket}

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
      case Enum.find(
             socket.assigns.provider_choices,
             &(&1.provider && provider_ref(&1.provider) == provider_key)
           ) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Unknown provider."))}

        %{provider: provider} ->
          credentials = credentials_of(socket, provider.id)
          credential_id = keep_or_default_credential(socket, credentials)

          changeset =
            socket.assigns.provider_form.source
            |> Ecto.Changeset.put_change(:credential_id, credential_id)

          {:noreply,
           socket
           |> apply_offer(provider, credentials, changeset, credential_id)
           |> reset_pool_selection()}
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
  #
  # Everything the discarded provider left behind goes with it: the key it had
  # selected (in the form AND in the assign the async guard reads), its
  # catalogue and the in-flight flag. Otherwise a late response still matched
  # the guard and painted that catalogue in a form with no provider.
  def handle_event("clear_provider_choice", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_form_provider_key, nil)
     |> assign(:provider_form_credential_id, nil)
     |> assign(:provider_form_is_fireworks, false)
     |> assign(:provider_credentials, nil)
     |> assign(:credential_form, nil)
     |> assign(:provider_models, [])
     |> assign(:provider_models_loading, false)
     |> assign(:provider_model_search, "")
     |> clear_form_credential()
     |> filter_provider_choices("")
     |> reset_pool_selection()
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
               credentials,
               changeset,
               credential.id
             )
             |> put_flash(:info, gettext("API key created and selected."))}

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
     |> assign(:lane_step, "credential")
     |> assign(:lane_step_error, nil)
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
     |> assign(:scope_member_open, false)
     |> reset_lane_source()}
  end

  def handle_event("edit_model_provider", %{"id" => ap_id}, socket) do
    {:noreply, open_lane_modal(socket, ap_id)}
  end

  ## Events — wizard del modal (credential → routing → pricing) --------------

  # Next valida el paso ACTIVO antes de avanzar: un paso a medias no deja
  # llegar al siguiente y el aviso se pinta en el propio paso (#lane-step-error).
  # Sin form abierto (evento encolado detrás de Cancelar) es un no-op.
  def handle_event("lane_next_step", _params, socket) do
    if socket.assigns.is_admin and socket.assigns[:provider_form] do
      case validate_lane_step(socket, socket.assigns[:lane_step]) do
        :ok ->
          {:noreply,
           socket
           |> assign(:lane_step, next_lane_step(socket.assigns[:lane_step]))
           |> assign(:lane_step_error, nil)}

        {:error, message} ->
          {:noreply, assign(socket, :lane_step_error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  # Back no revalida ni recasta nada: los assigns del form (y los pickers de
  # scope/provider/pool) siguen intactos entre pasos.
  def handle_event("lane_prev_step", _params, socket) do
    if socket.assigns.is_admin and socket.assigns[:provider_form] do
      {:noreply,
       socket
       |> assign(:lane_step, prev_lane_step(socket.assigns[:lane_step]))
       |> assign(:lane_step_error, nil)}
    else
      {:noreply, socket}
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
        # Un cambio del operador limpia el aviso del paso: el error era del
        # estado anterior, no de lo que acaba de escribir.
        |> assign(:lane_step_error, nil)
        # Lo tecleado manda: el re-render de un phx-change sale del changeset,
        # así que sin recastar lo que acaba de llegar el form devolvía los
        # valores viejos y borraba lo escrito (mismo mecanismo que el picker de
        # icono de labs).
        |> sync_submitted_form(ap_params)
        |> maybe_switch_lane_source(ap_params)

      cond do
        socket.assigns[:lane_source] == "pool" ->
          {:noreply, pool_form_changed(socket, ap_params)}

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
    with true <- socket.assigns.is_admin,
         %ModelProvider{} = ap <- fetch_lane(socket, ap_id) do
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
           |> load_lanes()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the provider."))}
      end
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      # Id forjado, lane inexistente o de otro modelo: no-op.
      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_model_provider", _params, socket), do: {:noreply, socket}

  def handle_event("delete_model_provider", %{"id" => ap_id}, socket) do
    with true <- socket.assigns.is_admin,
         %ModelProvider{} = ap <- fetch_lane(socket, ap_id) do
      case Providers.delete_model_provider(ap) do
        {:ok, _} ->
          audit(socket, "model_provider.delete", "model_provider", ap.id, %{
            "model_id" => ap.model_id
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Provider removed from the model."))
           |> load_lanes()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete the provider."))}
      end
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      # Id forjado, lane inexistente o de otro modelo: no-op.
      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_model_provider", _params, socket), do: {:noreply, socket}

  def handle_event("delete_pool", %{"id" => pool_id}, socket) do
    with true <- socket.assigns.is_admin,
         {:ok, pool_id} <- Ecto.UUID.cast(pool_id),
         %CredentialPool{} = pool <- Providers.get_pool(pool_id) do
      case Providers.delete_pool(pool) do
        {:ok, _pool} ->
          audit(socket, "pool.delete", "credential_pool", pool.id, %{
            "name" => pool.name,
            "provider_id" => pool.provider_id
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("Pool deleted."))
           |> assign_lane_pools()
           |> maybe_clear_lane_pool(pool.id)}

        {:error, :pool_in_use} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("This pool is mounted on a model. Remove the lane first.")
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete the pool."))}
      end
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      # Id forjado, pool inexistente o payload incompleto: no-op.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_pool", _params, socket), do: {:noreply, socket}

  def handle_event("reorder_providers", %{"model_id" => model_id, "ids" => ids}, socket) do
    with true <- socket.assigns.is_admin,
         {:ok, model_id} <- Ecto.UUID.cast(model_id),
         # El orden que llega es el de ESTA página: un model_id de otro modelo
         # (o forjado) no reordena nada.
         true <- model_id == socket.assigns.model.id do
      valid_ids =
        from(ap in ModelProvider, where: ap.model_id == ^model_id, select: ap.id)
        |> Repo.all()
        |> MapSet.new()

      if is_list(ids) and ids != [] and Enum.all?(ids, &MapSet.member?(valid_ids, &1)) do
        # UNA sentencia para todo el orden: `priority` sale de la POSICIÓN del id
        # en la lista. Un UPDATE por fila dentro de la transacción eran N round
        # trips (y N re-escrituras de los mismos índices) por un drag & drop.
        now = DateTime.truncate(DateTime.utc_now(), :second)

        {:ok, _} =
          Repo.transaction(fn ->
            from(ap in ModelProvider,
              where: ap.model_id == ^model_id and ap.id in ^ids,
              update: [
                set: [
                  priority: fragment("array_position(?::text[], ?::text)", ^ids, ap.id),
                  updated_at: ^now
                ]
              ]
            )
            |> Repo.update_all([])
          end)

        audit(socket, "model_provider.reorder", "model", model_id, %{"ids" => ids})

        {:noreply, load_lanes(socket)}
      else
        {:noreply, put_flash(socket, :error, gettext("Invalid order for this model."))}
      end
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      # model_id forjado (no UUID) o de otro modelo: no-op.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reorder_providers", _params, socket), do: {:noreply, socket}

  ## Events — pools de credenciales ------------------------------------------

  # Expande/colapsa el panel de miembros de un lane de pool. El estado vive en
  # un MapSet de ids de LANE (no de pool): el panel se pinta dentro de la fila
  # del lane y sobrevive a los `load_lanes/1` de toggle, quitar miembro y alta.
  def handle_event("toggle_pool_members", %{"id" => lane_id}, socket) do
    expanded = socket.assigns[:expanded_pools] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, lane_id) do
        MapSet.delete(expanded, lane_id)
      else
        MapSet.put(expanded, lane_id)
      end

    {:noreply, assign(socket, :expanded_pools, expanded)}
  end

  def handle_event("toggle_pool_members", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_new_pool", _params, socket) do
    {:noreply, assign(socket, :lane_new_pool_open, not socket.assigns[:lane_new_pool_open])}
  end

  # Quitar un miembro es SIEMPRE a través del contexto: es quien rechaza el
  # último (`{:error, :last_member}`) para que un pool no quede vacío. La UI no
  # duplica esa regla; sólo traduce el rechazo a un flash en español.
  def handle_event("remove_pool_member", %{"id" => member_id}, socket) do
    if socket.assigns.is_admin do
      with {:ok, member_id} <- Ecto.UUID.cast(member_id),
           %CredentialPoolMember{} = member <- Repo.get(CredentialPoolMember, member_id) do
        case Providers.remove_pool_member(member) do
          {:ok, _member} ->
            audit(socket, "pool_member.remove", "credential_pool", member.pool_id, %{
              "credential_id" => member.credential_id
            })

            {:noreply,
             socket
             |> put_flash(:info, gettext("API key removed from the pool."))
             |> load_lanes()}

          {:error, :last_member} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "A pool cannot be left without API keys. Delete the lane or the pool instead."
               )
             )}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, gettext("Could not remove the API key from the pool."))}
        end
      else
        # Id forjado (no UUID / inexistente): no-op, nunca un CastError que se
        # lleve el LiveView por delante.
        _ -> {:noreply, socket}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have permission for this action."))}
    end
  end

  def handle_event("remove_pool_member", _params, socket), do: {:noreply, socket}

  # Agregar una key a un pool existente. El select sólo ofrece credenciales del
  # proveedor del pool que todavía no son miembros; el contexto/DB repiten la
  # validación (`{:error, :provider_mismatch}` y la FK compuesta).
  def handle_event(
        "add_pool_member",
        %{"lane_id" => lane_id, "credential_id" => credential_id},
        socket
      ) do
    with true <- socket.assigns.is_admin,
         {:ok, lane_id} <- Ecto.UUID.cast(lane_id),
         {:ok, credential_id} <- Ecto.UUID.cast(credential_id),
         %ModelProvider{pool_id: pool_id} when is_binary(pool_id) <-
           Providers.get_model_provider(lane_id),
         %CredentialPool{} = pool <- Providers.get_pool(pool_id),
         %Credential{} = credential <- Providers.get_credential(credential_id) do
      case Providers.add_pool_member(pool, credential) do
        {:ok, _member} ->
          audit(socket, "pool_member.add", "credential_pool", pool.id, %{
            "credential_id" => credential.id
          })

          {:noreply,
           socket
           |> put_flash(:info, gettext("API key added to the pool."))
           |> load_lanes()}

        {:error, :provider_mismatch} ->
          {:noreply,
           put_flash(socket, :error, gettext("This API key belongs to another provider."))}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not add the API key: %{errors}", errors: error_messages(changeset))
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not add the API key to the pool."))}
      end
    else
      false ->
        {:noreply,
         put_flash(socket, :error, gettext("You do not have permission for this action."))}

      # Id forjado, lane sin pool o payload incompleto: no-op.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("add_pool_member", _params, socket), do: {:noreply, socket}

  # Abre el modal de un lane existente. `?edit=<id>` — el "Change" del modal del
  # modelo, que vive en el índice — entra por aquí también. Un id que no es de
  # este modelo no abre nada: la página se queda como está en vez de reventar.
  defp open_lane_modal(socket, ap_id) do
    with true <- socket.assigns.is_admin,
         %ModelProvider{} = ap <- fetch_lane(socket, ap_id) do
      open_lane_form(socket, ap)
    else
      _ -> socket
    end
  end

  defp open_lane_form(socket, ap) do
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

    # Un lane de pool no tiene credencial propia: la fuente es el pool, con
    # sus miembros. Se carga con `list_pool_members/1` (preload de credencial
    # y proveedor) para resolver de ahí el proveedor del modal — el mismo
    # criterio que `provider_key_of_credential/2` con una key.
    lane_pool = lane_pool(ap)
    pool_provider = lane_pool && pool_provider(lane_pool)
    provider_key = if pool_provider, do: provider_ref(pool_provider), else: provider_key

    # Prefill the service_tier checkbox from the stored extra_body (the
    # raw override virtuals are no longer part of the form). The provider is
    # already identified by the row's credential; el `provider_model` y los
    # precios manuales los escribe el operador (la lista viva del proveedor
    # es la que sugiere el id).
    changeset =
      changeset
      |> Ecto.Changeset.put_change(
        :service_tier_priority,
        Map.get(ap.extra_body || %{}, "service_tier") == "priority"
      )

    # The credential list is narrowed to the row's own provider, so editing an
    # assignment shows the keys that can actually serve it. The row's own key
    # is kept in the list even when it is not `active`: without it the select
    # could not represent the stored credential and the save failed on the
    # required field.
    lane_credential = credential_for_lane(socket, ap.credential_id)

    provider_credentials =
      cond do
        pool_provider ->
          credentials_of(socket, pool_provider.id)

        match?(%{provider_id: _}, lane_credential) ->
          %{provider_id: provider_id} = lane_credential
          credentials = credentials_of(socket, provider_id)

          if Enum.any?(credentials, &(&1.id == lane_credential.id)) do
            credentials
          else
            credentials ++ [lane_credential]
          end

        true ->
          []
      end

    # La lista viva del proveedor también aplica a un lane de pool: la key que
    # se usa para pedirla es un miembro cualquiera (todos son del proveedor
    # del pool), no la fuente del lane.
    fetch_credential_id =
      if lane_pool do
        lane_pool.members |> List.wrap() |> Enum.find_value(&member_credential_id/1)
      else
        ap.credential_id
      end

    socket
    |> assign(:provider_form, to_form(changeset, as: :model_provider))
    |> assign(:editing_ap_id, ap.id)
    # Edición: todo está ya decidido (key, scope, precio), así que el wizard
    # entra directo al último paso; Back lleva a routing/credential sin perder
    # nada.
    |> assign(:lane_step, "pricing")
    |> assign(:lane_step_error, nil)
    |> assign(:provider_form_model_id, ap.model_id)
    |> assign(:provider_form_credential_id, fetch_credential_id)
    |> assign(:provider_form_is_fireworks, pool_fireworks?(pool_provider, ap, socket))
    |> assign(:provider_form_pricing_unit, ap.pricing_unit || Pricing.default_unit())
    |> assign(:provider_form_provider_key, provider_key)
    |> assign(:provider_credentials, provider_credentials)
    |> assign(:lane_source, if(lane_pool, do: "pool", else: "key"))
    |> assign(:lane_pool_id, ap.pool_id)
    |> assign(:lane_pool_error, nil)
    |> assign(:lane_new_pool_open, false)
    |> assign(:provider_pools, lane_pool_pools(lane_pool))
    |> assign(:credential_form, nil)
    |> assign(:current_scope, scope)
    |> assign(:current_scope_group_id, ap.exclusive_to_group_id)
    |> assign(:current_scope_member_id, ap.exclusive_to_group_member_id)
    |> assign(:scope_group_search, group_label)
    |> assign(:scope_member_search, member_label)
    |> assign(:provider_models_loading, is_binary(fetch_credential_id))
    |> build_provider_choices(ap.model_id)
    |> assign_credential_choices()
    |> fetch_provider_models(fetch_credential_id)
  end

  ## Wizard del lane — pasos, validación y resumen --------------------------

  # Los tres pasos del modal. Los labels son msgid inglés (gettext); los crumbs
  # NO son clicables: avanzar y volver los gobiernan `lane_next_step` /
  # `lane_prev_step`, que validan el paso activo.
  defp lane_steps do
    [
      {"credential", gettext("Credential")},
      {"routing", gettext("Routing")},
      {"pricing", gettext("Pricing")}
    ]
  end

  defp next_lane_step("credential"), do: "routing"
  defp next_lane_step(_step), do: "pricing"

  defp prev_lane_step("pricing"), do: "routing"
  defp prev_lane_step(_step), do: "credential"

  # Validación por paso: sólo se valida el paso ACTIVO al pulsar Next. Los
  # campos llegan por el `phx-change` del form (que recasta en cada tecla), así
  # que validar aquí no pierde nada de lo escrito ni toca la DB.
  defp validate_lane_step(socket, "credential"), do: validate_credential_step(socket)
  defp validate_lane_step(socket, "routing"), do: validate_routing_step(socket)
  # El paso de precios no avanza a ningún sitio: su validación es el submit, que
  # corre el changeset completo (la unidad es una lista cerrada, `Pricing.units/0`).
  defp validate_lane_step(_socket, _step), do: :ok

  defp validate_credential_step(socket) do
    form = socket.assigns[:provider_form]

    cond do
      is_nil(form) ->
        {:error, gettext("The credential form is missing.")}

      blank_value?(form[:provider_model].value) ->
        {:error, gettext("Pick or type the provider model first.")}

      socket.assigns[:lane_source] == "pool" ->
        validate_pool_step(form)

      blank_value?(form[:credential_id].value) ->
        {:error, gettext("Pick the API key that will serve this model")}

      true ->
        :ok
    end
  end

  # Un pool es la fuente: o uno existente elegido, o uno nuevo con nombre y al
  # menos una key. El mismo criterio que `plan_pool_source/2`, pero ANTES de
  # dejar avanzar.
  defp validate_pool_step(form) do
    new_name? = not blank_value?(form[:new_pool_name].value)

    cond do
      not new_name? and blank_value?(form[:pool_id].value) ->
        {:error, gettext("Pick an existing pool or create a new one.")}

      new_name? and new_pool_member_ids(form) == [] ->
        {:error, gettext("Select at least one API key for the new pool.")}

      true ->
        :ok
    end
  end

  # Un scope exclusivo sin destino no puede degradarse a global en silencio
  # (L37): el paso de routing lo rechaza antes de llegar al save.
  defp validate_routing_step(socket) do
    scope = socket.assigns[:current_scope] || "global"

    cond do
      scope == "member" and
          missing_scope_target?(socket, :current_scope_member_ids, :current_scope_member_id) ->
        {:error, gettext("Select at least one limit profile or user for the exclusive scope.")}

      scope == "group" and
          missing_scope_target?(socket, :current_scope_group_ids, :current_scope_group_id) ->
        {:error, gettext("Select at least one limit profile or user for the exclusive scope.")}

      true ->
        :ok
    end
  end

  # El alta es multi-select (`*_ids`); la edición guarda un único id.
  defp missing_scope_target?(socket, ids_key, id_key) do
    if socket.assigns[:editing_ap_id] == :new do
      List.wrap(socket.assigns[ids_key]) == []
    else
      blank_id?(socket.assigns[id_key])
    end
  end

  defp new_pool_member_ids(form) do
    case form[:new_pool_member_ids].value do
      ids when is_list(ids) -> Enum.reject(ids, &blank_value?/1)
      _ -> []
    end
  end

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(_value), do: false

  # Al fallar el save, el modal salta al paso dueño del primer error: el error
  # de la fuente (pool/key) vive en un bloque que, en otro paso, quedaría
  # oculto y el operador no sabría qué corregir.
  defp lane_step_with_error(%Ecto.Changeset{} = changeset, current) do
    fields = Enum.map(changeset.errors, fn {field, _error} -> field end)

    cond do
      Enum.any?(fields, &(&1 in @pricing_fields)) -> "pricing"
      Enum.any?(fields, &(&1 in @routing_fields)) -> "routing"
      Enum.any?(fields, &(&1 in @credential_fields)) -> "credential"
      true -> current
    end
  end

  ## Resumen del paso de precios -------------------------------------------

  defp lane_summary_provider(assigns) do
    case assigns[:provider_form_provider_key] do
      nil -> "—"
      provider_ref_key -> provider_label(assigns[:provider_choices] || [], provider_ref_key)
    end
  end

  defp lane_summary_credential(%{lane_source: "pool"} = assigns) do
    pool_name =
      case Enum.find(assigns[:provider_pools] || [], &(&1.id == assigns[:lane_pool_id])) do
        %CredentialPool{name: name} -> name
        _ -> nil
      end

    pool_name || assigns.provider_form[:new_pool_name].value || "—"
  end

  defp lane_summary_credential(assigns) do
    credential =
      Enum.find(
        assigns[:credential_choices] || [],
        &(&1.id == assigns[:provider_form_credential_id])
      )

    case credential do
      %Credential{name: name} when is_binary(name) and name != "" -> name
      %Credential{} -> gettext("unnamed key")
      _ -> "—"
    end
  end

  defp lane_summary_scope(assigns) do
    scope = assigns[:current_scope] || "global"

    target =
      case scope do
        "group" -> assigns[:scope_group_search]
        "member" -> assigns[:scope_member_search]
        _ -> nil
      end

    if blank_value?(target) do
      scope_label(scope)
    else
      "#{scope_label(scope)} · #{target}"
    end
  end

  ## Async: catálogo del proveedor --------------------------------------

  @impl true
  def handle_info(
        {:provider_models_result, credential_id, result},
        %{assigns: assigns} = socket
      ) do
    # Discard stale responses: only the most recent credential change wins.
    if credential_id == assigns[:provider_form_credential_id] do
      case result do
        {:ok, models} ->
          # `provider_model_search` is NOT reset: it is the filter the operator
          # typed into `provider_model`, not a piece of the listing state.
          {:noreply,
           socket
           |> assign(:provider_models, models)
           |> assign(:provider_models_loading, false)}

        {:error, _reason} ->
          # Same: the typed filter survives the failed listing.
          {:noreply,
           socket
           |> assign(:provider_models, [])
           |> assign(:provider_models_loading, false)
           |> put_flash(:error, gettext("Could not load the provider models."))}
      end
    else
      {:noreply, socket}
    end
  end

  ## Private helpers — scope y guardado --------------------------------

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
          try do
            if model_type == "embedding" do
              adapter.list_embedding_models(provider, credential)
            else
              Tokengate.Proxy.OpenAIAdapter.list_models(provider, credential)
            end
          rescue
            # Igual que el wizard: un raise del adapter no puede dejar
            # `provider_models_loading` colgado en true para siempre.
            e -> {:error, Exception.message(e)}
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

  defp apply_provider_defaults(ap_params, _socket) do
    Map.drop(ap_params, ["extra_body_json", "omit_body_fields_csv", "omit_headers_csv"])
  end

  ## Private helpers — exclusive scope (L37) ---------------------------------

  # "group"/"member" son un límite de acceso: exigen un destino concreto. Un
  # scope exclusivo sin selección no puede degradarse a global en silencio.
  defp exclusive_scope?(scope), do: scope in ["group", "member"]

  defp selection_empty?("group", group_ids, _member_ids), do: group_ids == []
  defp selection_empty?("member", _group_ids, member_ids), do: member_ids == []
  defp selection_empty?(_scope, _group_ids, _member_ids), do: false

  defp exclusive_scope_key("group"), do: "exclusive_to_group_id"
  defp exclusive_scope_key("member"), do: "exclusive_to_group_member_id"

  defp blank_id?(nil), do: true
  defp blank_id?(""), do: true
  defp blank_id?(_id), do: false

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

    scope = socket.assigns[:current_scope] || "global"

    # L37 — el scope es una frontera de permisos, no un modo de presentación.
    # Sin esta validación el constructor de targets siempre devuelve al menos
    # [ap_params], así que un lane exclusivo sin selección caía al insert
    # global y dejaba el modelo abierto a todos.
    if exclusive_scope?(scope) and selection_empty?(scope, group_ids, member_ids) do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Select at least one limit profile or user for the exclusive scope.")
       )}
    else
      # La fuente (con su pool NUEVO, si lo hay) se materializa DENTRO de la
      # transacción del insert: un lane que no se puede guardar no deja atrás un
      # pool huérfano con el nombre ya ocupado.
      case write_lane(socket, ap_params, fn resolved ->
             create_lane_targets(resolved, group_ids, member_ids)
           end) do
        {:ok, count} ->
          lane_created(socket, scope, count)

        {:error, {:source, message}} ->
          lane_source_error(socket, ap_params, message)

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Could not assign: %{errors}",
               errors: Enum.map_join(changeset.errors, ", ", fn {_f, {m, _}} -> m end)
             )
           )
           |> assign(:lane_pool_error, lane_error_in_modal(socket, changeset))
           |> assign(:lane_step, lane_step_with_error(changeset, socket.assigns[:lane_step]))
           |> assign(:provider_form, to_form(changeset, as: :model_provider))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not assign: %{errors}", errors: inspect(reason))
           )}
      end
    end
  end

  # L38 — un id de edición stale (doble submit, submit encolado detrás de
  # Cancelar) es un no-op: sin esta cláusula revienta con FunctionClauseError y
  # se lleva la LiveView y el formulario por delante.
  defp save_model_provider(socket, nil, _ap_params), do: {:noreply, socket}

  defp save_model_provider(socket, ap_id, ap_params) when is_binary(ap_id) do
    scope = socket.assigns[:current_scope] || "global"
    # Lane borrado o de otro modelo entre el render y el submit: no-op (nunca un
    # NoResultsError, ni una escritura cruzada).
    lane = fetch_lane(socket, ap_id)

    # L37 en edición: cambiar el scope a group/member sin elegir destino
    # guardaría el lane como global (ambos FKs nil). Mismo rechazo que en alta.
    cond do
      exclusive_scope?(scope) and blank_id?(Map.get(ap_params, exclusive_scope_key(scope))) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Select at least one limit profile or user for the exclusive scope.")
         )}

      is_nil(lane) ->
        {:noreply, socket}

      true ->
        case write_lane(socket, ap_params, fn resolved ->
               Providers.update_model_provider(lane, apply_provider_defaults(resolved, socket))
             end) do
          {:ok, updated_ap} ->
            lane_updated(socket, updated_ap, ap_params)

          {:error, {:source, message}} ->
            lane_source_error(socket, ap_params, message)

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:lane_pool_error, lane_error_in_modal(socket, changeset))
             |> assign(:lane_step, lane_step_with_error(changeset, socket.assigns[:lane_step]))
             |> assign(:provider_form, to_form(changeset, as: :model_provider))}

          {:error, _reason} ->
            {:noreply, socket}
        end
    end
  end

  # Los targets del alta: un set de params por grupo/usuario exclusivo, o uno
  # solo global.
  defp create_lane_targets(ap_params, group_ids, member_ids) do
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

        true ->
          # Global scope
          [ap_params]
      end

    # Los inserts van en una sola transacción: si un target choca con el
    # índice de exclusividad única (mismo modelo+target ya tiene dueño),
    # no debe quedar un estado parcial con la mitad de los targets
    # asignados. O entran todos, o ninguno.
    Providers.create_model_providers_transactional(targets)
  end

  defp lane_created(socket, scope, count) do
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
     |> assign(:lane_step, "credential")
     |> assign(:lane_step_error, nil)
     # The modal is closing: nothing is in flight anymore, so the spinner
     # must not leak into the next one.
     |> assign(:provider_models_loading, false)
     |> assign(:lane_pool_error, nil)
     |> reset_lane_source()
     |> load_lanes()}
  end

  defp lane_updated(socket, updated_ap, ap_params) do
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
     |> assign(:lane_step, "credential")
     |> assign(:lane_step_error, nil)
     # Same as the create path: closing the modal ends any listing state.
     |> assign(:provider_models_loading, false)
     |> assign(:lane_pool_error, nil)
     |> reset_lane_source()
     |> load_lanes()}
  end

  # Toda escritura de un lane va en UNA transacción con la materialización de su
  # fuente: el pool nuevo se crea DENTRO, así que un lane rechazado no deja un
  # pool huérfano (ni su nombre ocupado para el reintento).
  defp write_lane(socket, ap_params, write) do
    Repo.transaction(fn ->
      with {:ok, source} <- plan_lane_source(socket, ap_params),
           {:ok, resolved} <- materialize_lane_source(source),
           {:ok, value} <- write.(resolved) do
        value
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
        {:error, message} when is_binary(message) -> Repo.rollback({:source, message})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  ## Private helpers — pools de credenciales --------------------------------

  # Estado del modal en reposo: la fuente vuelve a la key y todo lo del pool se
  # limpia. Se usa al abrir el alta, al cancelar y al guardar.
  defp reset_lane_source(socket) do
    socket
    |> assign(:lane_source, "key")
    |> assign(:lane_pool_id, nil)
    |> assign(:lane_pool_error, nil)
    |> assign(:lane_new_pool_open, false)
    |> assign(:provider_pools, [])
  end

  defp lane_source_param(params, current) do
    case Map.get(params, "source") do
      "pool" -> "pool"
      "key" -> "key"
      _ -> current || "key"
    end
  end

  # El radio de fuente del form dispara el `phx-change` del modal entero, así
  # que el cambio de fuente se detecta ahí y no en un evento propio: lo que
  # llega es el form completo, y los campos ya escritos se conservan.
  #
  # Sin form abierto no hay fuente que cambiar: un `phx-change` encolado detrás
  # de Cancelar es un no-op, no un BadMapError.
  defp maybe_switch_lane_source(%{assigns: %{provider_form: nil}} = socket, _ap_params),
    do: socket

  defp maybe_switch_lane_source(socket, ap_params) do
    source = lane_source_param(ap_params, socket.assigns[:lane_source])

    if source == socket.assigns[:lane_source] do
      socket
    else
      switch_lane_source(socket, source, ap_params)
    end
  end

  # Al cambiar de fuente se limpia el campo de la OTRA: en modo pool la
  # credencial del lane sobra (el XOR la rechazaría) y en modo key el pool
  # sobra por la misma razón.
  defp switch_lane_source(socket, "pool", ap_params) do
    changeset =
      socket.assigns.provider_form.source
      |> carry_submitted_params(ap_params)
      |> Ecto.Changeset.put_change(:credential_id, nil)

    socket
    |> assign(:provider_form, to_form(changeset, as: :model_provider))
    |> assign(:lane_source, "pool")
    |> assign(:lane_pool_id, nil)
    |> assign(:lane_pool_error, nil)
    |> assign(:lane_new_pool_open, false)
    |> assign_lane_pools()
  end

  defp switch_lane_source(socket, "key", ap_params) do
    changeset =
      socket.assigns.provider_form.source
      |> carry_submitted_params(ap_params)
      |> Ecto.Changeset.put_change(:pool_id, nil)

    socket
    |> assign(:provider_form, to_form(changeset, as: :model_provider))
    |> assign(:lane_source, "key")
    |> assign(:lane_pool_id, nil)
    |> assign(:lane_pool_error, nil)
    |> assign(:lane_new_pool_open, false)
    |> assign(:provider_pools, [])
  end

  defp pool_form_changed(socket, ap_params) do
    # Un payload parcial (sin `pool_id`) no borra la selección: el navegador
    # manda el form completo, pero un evento suelto no tiene por qué hacerlo.
    pool_id =
      if Map.has_key?(ap_params, "pool_id") do
        blank_to_nil(ap_params["pool_id"])
      else
        socket.assigns[:lane_pool_id]
      end

    cond do
      is_nil(pool_id) ->
        socket
        |> assign(:lane_pool_id, nil)
        |> assign(:lane_pool_error, nil)

      pool_id == socket.assigns[:lane_pool_id] ->
        socket

      true ->
        select_lane_pool(socket, pool_id, ap_params)
    end
  end

  # Elegir un pool existente es el equivalente de elegir una key: deriva el
  # proveedor (del propio pool), deja el chip puesto y pide la lista viva de
  # modelos con un miembro cualquiera — todos son del mismo proveedor.
  defp select_lane_pool(socket, pool_id, ap_params) do
    case Enum.find(socket.assigns[:provider_pools] || [], &(&1.id == pool_id)) do
      %CredentialPool{} = pool ->
        changeset =
          socket.assigns.provider_form.source
          |> carry_submitted_params(ap_params)
          |> Ecto.Changeset.put_change(:pool_id, pool.id)
          |> Ecto.Changeset.put_change(:credential_id, nil)

        credential = pool_first_credential(pool)

        socket
        |> assign(:provider_form, to_form(changeset, as: :model_provider))
        |> assign(:lane_pool_id, pool.id)
        |> assign(:lane_pool_error, nil)
        |> ensure_pool_provider(pool)
        |> assign(:provider_form_credential_id, credential && credential.id)
        |> assign(:provider_models_loading, not is_nil(credential))
        |> fetch_provider_models(credential && credential.id)

      _ ->
        socket
    end
  end

  defp ensure_pool_provider(socket, %CredentialPool{provider_id: provider_id}) do
    if socket.assigns[:provider_form_provider_key] do
      socket
    else
      case Providers.get_provider(provider_id) do
        %Provider{} = provider ->
          socket
          |> assign(:provider_form_provider_key, provider_ref(provider))
          |> assign(:provider_form_is_fireworks, provider.key == "fireworks-ai")
          |> assign(:provider_credentials, credentials_of(socket, provider.id))
          |> assign_credential_choices()

        _ ->
          socket
      end
    end
  end

  # Cambiar de proveedor invalida la selección de pool: los pools son del
  # proveedor, así que la lista se recarga y el pool elegido se suelta — un pool
  # de otro proveedor no puede quedar montado por inercia.
  defp reset_pool_selection(socket) do
    if socket.assigns[:lane_source] == "pool" do
      socket =
        case socket.assigns[:provider_form] do
          %{source: source} ->
            changeset = Ecto.Changeset.put_change(source, :pool_id, nil)
            assign(socket, :provider_form, to_form(changeset, as: :model_provider))

          _ ->
            socket
        end

      socket
      |> assign(:lane_pool_id, nil)
      |> assign(:lane_pool_error, nil)
      |> assign(:lane_new_pool_open, false)
      |> assign_lane_pools()
    else
      socket
    end
  end

  defp assign_lane_pools(socket) do
    pools =
      case pool_form_provider(socket) do
        %Provider{id: provider_id} -> Providers.list_pools_for_provider(provider_id)
        _ -> []
      end

    assign(socket, :provider_pools, pools)
  end

  defp pool_form_provider(socket) do
    provider_by_ref(
      socket.assigns[:provider_choices],
      List.wrap(socket.assigns[:provider_credentials]) ++
        List.wrap(socket.assigns[:credentials_for_select]),
      socket.assigns[:provider_form_provider_key]
    )
  end

  # Traduce la fuente elegida en el modal a un PLAN de escritura. Aquí NO se
  # escribe nada: el pool nuevo se materializa dentro de la transacción del lane
  # (`write_lane/3`), para que un lane que no se puede guardar no deje un pool
  # huérfano con el nombre ya ocupado.
  defp plan_lane_source(socket, ap_params) do
    case lane_source_param(ap_params, socket.assigns[:lane_source]) do
      "pool" ->
        plan_pool_source(socket, ap_params)

      _key ->
        # Convertir un lane de pool a lane de una key LIMPIA el pool: `nil`
        # explícito, no `Map.drop` (el changeset re-lee la fila de la DB, donde
        # pool_id sigue puesto, y el XOR rechazaría las dos fuentes).
        {:ok,
         {:key,
          ap_params
          |> Map.put("pool_id", nil)
          |> Map.drop(["new_pool_name", "new_pool_member_ids"])}}
    end
  end

  defp plan_pool_source(socket, ap_params) do
    new_name = (ap_params["new_pool_name"] || "") |> to_string() |> String.trim()
    member_ids = ap_params["new_pool_member_ids"] |> List.wrap() |> Enum.reject(&blank_id?/1)
    pool_id = blank_to_nil(ap_params["pool_id"])

    # La credencial propia del lane no viaja en modo pool: la fuente es el pool
    # y el XOR del changeset rechazaría las dos.
    ap_params = Map.put(ap_params, "credential_id", nil)

    cond do
      new_name != "" ->
        with %Provider{} = provider <- selected_provider(socket),
             {:ok, member_ids} <- pool_member_ids(provider, member_ids) do
          {:ok, {:new_pool, provider, new_name, member_ids, ap_params}}
        else
          nil -> {:error, gettext("Pick the provider the pool belongs to first.")}
          {:error, message} -> {:error, message}
        end

      is_nil(pool_id) ->
        {:error, gettext("Pick an existing pool or create a new one.")}

      true ->
        case Enum.find(socket.assigns[:provider_pools] || [], &(&1.id == pool_id)) do
          %CredentialPool{} -> {:ok, {:existing_pool, Map.put(ap_params, "pool_id", pool_id)}}
          _ -> {:error, gettext("Pick an existing pool or create a new one.")}
        end
    end
  end

  # Los ids del pool nuevo se validan CONTRA el proveedor elegido antes de
  # escribir nada: una credencial borrada entre el render y el submit (o forjada)
  # es un rechazo entero, no un pool con la mitad de las keys.
  defp pool_member_ids(_provider, []),
    do: {:error, gettext("Select at least one API key for the new pool.")}

  defp pool_member_ids(provider, member_ids) do
    ids =
      Enum.flat_map(member_ids, fn credential_id ->
        case Ecto.UUID.cast(credential_id) do
          {:ok, id} -> [id]
          :error -> []
        end
      end)

    valid_ids =
      from(c in Credential,
        where: c.provider_id == ^provider.id and c.id in ^ids,
        select: c.id
      )
      |> Repo.all()
      |> MapSet.new()

    cond do
      ids == [] ->
        {:error, gettext("Select at least one API key for the new pool.")}

      not Enum.all?(ids, &MapSet.member?(valid_ids, &1)) ->
        {:error, gettext("One of the selected API keys is not valid for this pool.")}

      true ->
        {:ok, ids}
    end
  end

  # Materializa el plan dentro de la transacción del lane: el pool nuevo (y su
  # membresía) nacen ahí, así que un fallo posterior en el lane los revierte.
  defp materialize_lane_source({:key, ap_params}), do: {:ok, ap_params}
  defp materialize_lane_source({:existing_pool, ap_params}), do: {:ok, ap_params}

  defp materialize_lane_source({:new_pool, provider, name, member_ids, ap_params}) do
    with {:ok, pool} <- Providers.create_pool(provider, %{"name" => name}),
         :ok <- add_members_to_pool(pool, member_ids) do
      {:ok, Map.put(ap_params, "pool_id", pool.id)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         gettext("Could not create the pool: %{errors}", errors: error_messages(changeset))}

      {:error, _reason} ->
        {:error, gettext("One of the selected API keys is not valid for this pool.")}
    end
  end

  defp add_members_to_pool(pool, member_ids) do
    Enum.reduce_while(member_ids, :ok, fn credential_id, :ok ->
      case add_member_to_pool(pool, credential_id) do
        {:ok, _member} -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp add_member_to_pool(pool, credential_id) do
    with {:ok, credential_id} <- Ecto.UUID.cast(credential_id),
         %Credential{} = credential <- Providers.get_credential(credential_id) do
      Providers.add_pool_member(pool, credential)
    else
      _ -> :error
    end
  end

  # El error de la fuente no cierra el modal ni pierde lo escrito: el changeset
  # se recasta con el último envío y el mensaje va al bloque del pool, que es el
  # único sitio visible cuando el select de la key está oculto.
  defp lane_source_error(socket, ap_params, message) do
    case socket.assigns[:provider_form] do
      %{source: source} ->
        changeset = carry_submitted_params(source, ap_params)

        {:noreply,
         socket
         |> assign(:lane_pool_error, message)
         # El fallo es de la FUENTE (pool/key): su bloque vive en el paso 1.
         |> assign(:lane_step, "credential")
         |> assign(:provider_form, to_form(changeset, as: :model_provider))}

      _ ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Al borrar el pool seleccionado en el modal, el select no puede quedarse con
  # un id que ya no existe.
  defp maybe_clear_lane_pool(socket, pool_id) do
    if socket.assigns[:lane_pool_id] == pool_id do
      assign(socket, :lane_pool_id, nil)
    else
      socket
    end
  end

  # Los errores del changeset que caen en campos que el form no pinta (el XOR,
  # la fuente faltante) se resumen en el bloque de error del modal, en AMBOS
  # modos: en modo pool es el único aviso visible.
  defp lane_error_in_modal(_socket, changeset) do
    case error_messages(changeset) do
      "" -> nil
      errors -> gettext("Could not save: %{errors}", errors: errors)
    end
  end

  defp error_messages(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ", ", fn {_field, {message, _opts}} -> message end)
  end

  # Un checkbox del alta de pool vuelve marcado tras un error: el último envío
  # del form queda en los params del changeset y ahí viajan los ids elegidos.
  defp new_pool_member_checked?(form, credential_id) do
    case form[:new_pool_member_ids].value do
      ids when is_list(ids) -> credential_id in ids
      _ -> false
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_value), do: nil

  # El pool de un lane, con sus miembros y cada credencial con su proveedor.
  defp lane_pool(%ModelProvider{pool_id: nil}), do: nil

  defp lane_pool(%ModelProvider{pool_id: pool_id}) do
    case Providers.get_pool(pool_id) do
      nil -> nil
      pool -> %{pool | members: Providers.list_pool_members(pool)}
    end
  end

  defp lane_pool_pools(nil), do: []

  defp lane_pool_pools(%CredentialPool{provider_id: provider_id}),
    do: Providers.list_pools_for_provider(provider_id)

  defp pool_first_credential(%CredentialPool{members: members}) do
    members
    |> List.wrap()
    |> Enum.find_value(fn
      %{credential: %Credential{} = credential} -> credential
      _ -> nil
    end)
  end

  defp member_credential_id(%{credential_id: id}) when is_binary(id), do: id
  defp member_credential_id(_member), do: nil

  defp pool_provider(%CredentialPool{} = pool) do
    case pool_first_credential(pool) do
      %Credential{provider: %Provider{} = provider} -> provider
      _ -> pool.provider_id && Providers.get_provider(pool.provider_id)
    end
  end

  defp pool_fireworks?(nil, ap, socket), do: credential_is_fireworks?(ap.credential_id, socket)
  defp pool_fireworks?(%Provider{key: key}, _ap, _socket), do: key == "fireworks-ai"

  defp pool_fireworks?(_provider, ap, socket),
    do: credential_is_fireworks?(ap.credential_id, socket)

  ## Helpers de presentación -------------------------------------------

  def provider_label(choices, provider_ref_key) do
    case provider_by_ref(choices, [], provider_ref_key) do
      %{name: name} -> name
      _ -> provider_ref_key
    end
  end

  @doc """
  Nombre del proveedor elegido en el modal. Sale de la lista de ofertas del
  modelo; un ref de un proveedor que no sirve este modelo no entra a esa lista,
  así que se resuelve por la credencial (el proveedor siempre es conocido: es
  quien emitió la key).
  """
  def provider_chip_name(choices, credentials, provider_ref_key) do
    case provider_by_ref(choices, credentials, provider_ref_key) do
      %{name: name} when is_binary(name) -> name
      _ -> provider_ref_key
    end
  end

  @doc """
  La key de catálogo que se muestra junto al nombre del chip: `nil` para un
  custom — su id no es material de exhibición.
  """
  def provider_key_label(choices, credentials, provider_ref_key) do
    case provider_by_ref(choices, credentials, provider_ref_key) do
      %{key: key} when is_binary(key) -> key
      _ -> nil
    end
  end

  # Resuelve un ref (`provider_ref/1`) contra la lista de ofertas del modelo y,
  # en su defecto, contra las credenciales cargadas (cada una trae su proveedor).
  defp provider_by_ref(choices, credentials, provider_ref_key) do
    with %{provider: provider} <-
           Enum.find(
             List.wrap(choices),
             &(&1.provider && provider_ref(&1.provider) == provider_ref_key)
           ) do
      provider
    else
      _ ->
        case Enum.find(List.wrap(credentials), &(provider_ref(&1.provider) == provider_ref_key)) do
          nil -> nil
          credential -> credential.provider
        end
    end
  end

  defp build_provider_choices(socket, model_id) do
    choices = all_active_providers()

    # El tipo sale del modelo al que se le añade el lane, NUNCA del tipo que el
    # operador eligió en el wizard del alta: ese assign se quedaba pegado tras
    # guardar y acotaba el picker de cualquier otro modelo (ocultaba
    # proveedores válidos y vaciaba la lista).
    choices =
      case Providers.get_model(model_id) do
        %Model{model_type: type} -> filter_choices_by_capability(choices, type || "llm")
        _ -> choices
      end

    socket
    |> assign(:provider_choices, choices)
    |> filter_provider_choices("")
  end

  # llm/embedding son capabilities declaradas; los tres servicios también lo
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
    |> Enum.map(&%{provider: &1})
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

  # The provider of the modal is the one that OWNS the selected API key: every
  # credential belongs to exactly one provider. Resolving it against
  # `provider_choices` (active providers, filtered by the model's type) made the
  # chip show a provider that "New API key" then claimed was not picked.
  defp selected_provider(socket) do
    credentials =
      List.wrap(socket.assigns[:provider_credentials]) ++
        List.wrap(socket.assigns[:credentials_for_select])

    case socket.assigns[:provider_form_credential_id] do
      nil ->
        provider_by_ref(
          socket.assigns[:provider_choices],
          credentials,
          socket.assigns[:provider_form_provider_key]
        )

      credential_id ->
        case Enum.find(credentials, &(&1.id == credential_id)) do
          %{provider: provider} ->
            provider

          _ ->
            provider_by_ref(
              socket.assigns[:provider_choices],
              credentials,
              socket.assigns[:provider_form_provider_key]
            )
        end
    end
  end

  # The form's own `credential_id` must go too when the provider choice is
  # discarded: the select would otherwise keep the old key with no provider.
  defp clear_form_credential(socket) do
    case socket.assigns[:provider_form] do
      nil ->
        socket

      form ->
        changeset = Ecto.Changeset.put_change(form.source, :credential_id, nil)
        assign(socket, :provider_form, to_form(changeset, as: :model_provider))
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

  defp provider_key_of_credential(_socket, nil), do: nil

  defp provider_key_of_credential(socket, credential_id) do
    case credential_for_lane(socket, credential_id) do
      # Ref, no key: un custom no tiene key de catálogo y sin ref el chip del
      # modal lo daría por no elegido.
      %{provider: provider} -> provider_ref(provider)
      _ -> nil
    end
  end

  # The row's own credential, even when it is NOT `active`: a key that went
  # disabled/error still owns its lane, so editing it must resolve its provider
  # and keep it selectable instead of showing an empty modal.
  defp credential_for_lane(socket, credential_id) when is_binary(credential_id) do
    case Enum.find(socket.assigns[:credentials_for_select] || [], &(&1.id == credential_id)) do
      nil ->
        case Repo.get(Tokengate.Providers.Credential, credential_id) do
          nil -> nil
          credential -> Repo.preload(credential, :provider)
        end

      credential ->
        credential
    end
  end

  defp credential_for_lane(_socket, _credential_id), do: nil

  # One place where picking a provider (or creating its key) turns into modal
  # state: the form's credential, the provider key, the credential list narrowed
  # to that provider, and the provider's live catalogue loaded for the suggestion
  # list (which is also where the operator picks the `provider_model`).
  defp apply_offer(socket, provider, credentials, changeset, credential_id) do
    socket =
      socket
      |> assign(:provider_form, to_form(changeset, as: :model_provider))
      |> assign(:provider_form_provider_key, provider_ref(provider))
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

  # Elegir la API key es lo que fija la relación modeloproveedor: cada
  # credencial pertenece a un solo proveedor, así que la key resuelve por sí
  # sola el proveedor del modal. El `provider_model` no se prellena: sale de la
  # lista viva del proveedor (`provider_models`), que el operador ve y elige.
  defp apply_credential_provider(socket, credential_id, ap_params) do
    case Enum.find(socket.assigns[:credentials_for_select] || [], &(&1.id == credential_id)) do
      %{provider: provider} ->
        credentials = credentials_of(socket, provider.id)

        changeset =
          socket.assigns.provider_form.source
          |> carry_submitted_params(ap_params)
          |> Ecto.Changeset.put_change(:credential_id, credential_id)

        socket
        |> assign(:provider_form, to_form(changeset, as: :model_provider))
        |> assign(:provider_form_provider_key, provider_ref(provider))
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

  # Rearma el changeset del form abierto con lo que acaba de llegar del cliente.
  # Es lo que hace que el re-render de un `phx-change` NO revierta los campos
  # tecleados cuando el evento no cambia nada más (una key sin elegir, un evento
  # que no toca la fuente); sin form abierto es un no-op.
  defp sync_submitted_form(%{assigns: %{provider_form: nil}} = socket, _ap_params), do: socket

  defp sync_submitted_form(socket, ap_params) do
    changeset = carry_submitted_params(socket.assigns.provider_form.source, ap_params)
    assign(socket, :provider_form, to_form(changeset, as: :model_provider))
  end

  # The credentials the modal's select lists: just the selected provider's keys
  # once a provider is chosen, every active credential until then.
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
        gettext("All")
    end
  end

  def scope_group(%ModelProvider{exclusive_to_group_member_id: id}) when not is_nil(id), do: 2
  def scope_group(%ModelProvider{exclusive_to_group_id: id}) when not is_nil(id), do: 1
  def scope_group(%ModelProvider{}), do: 0

  @doc "Group header label (nil for the global group — no header needed)"
  def scope_group_label(1), do: gettext("Exclusive per limit profile")
  def scope_group_label(2), do: gettext("Exclusive per user")
  def scope_group_label(_), do: nil

  def provider_name(%ModelProvider{credential: %{provider: %Provider{} = provider}}),
    do: provider.name

  # Un lane de pool no tiene credencial: el proveedor es el del pool, y como el
  # pool no lo precarga se resuelve por sus miembros (todos del mismo
  # proveedor, la FK compuesta lo garantiza).
  def provider_name(%ModelProvider{pool: %{members: members}}) when is_list(members),
    do: pool_provider_name(members)

  def provider_name(%Credential{provider: %Provider{} = provider}), do: provider.name

  def provider_name(_), do: "—"

  defp pool_provider_name(members) do
    case Enum.find(members, &match?(%{credential: %{provider: %Provider{}}}, &1)) do
      %{credential: %{provider: %Provider{name: name}}} when is_binary(name) -> name
      _ -> "—"
    end
  end

  def credential_named?(%{name: name}) when is_binary(name) and name != "", do: true
  def credential_named?(_), do: false

  ## Presentación de pools ---------------------------------------------

  @doc "Cantidad de keys de un lane de pool (0 para un lane de credencial)."
  def pool_member_count(%ModelProvider{pool: %{members: members}}) when is_list(members),
    do: length(members)

  def pool_member_count(_ap), do: 0

  @doc "Etiqueta de un miembro del pool: el alias de su credencial."
  def pool_member_label(%{credential: %Credential{} = credential}) do
    credential.name || gettext("unnamed key")
  end

  def pool_member_label(member), do: to_string(Map.get(member, :credential_id) || "—")

  def pool_member_mask(%{credential: %Credential{} = credential}),
    do: mask_key(credential.api_key_encrypted)

  def pool_member_mask(_member), do: "—"

  def pool_member_active?(%{credential: %{status: "active"}}), do: true
  def pool_member_active?(_member), do: false

  @doc """
  Credenciales del proveedor del pool que todavía no son miembros — las únicas
  que tiene sentido ofrecer en el alta de miembro.
  """
  def pool_add_options(%CredentialPool{} = pool, credentials) do
    member_ids = pool.members |> List.wrap() |> Enum.map(& &1.credential_id)

    List.wrap(credentials)
    |> Enum.filter(&(&1.provider_id == pool.provider_id))
    |> Enum.reject(&(&1.id in member_ids))
  end

  def pool_add_options(_pool, _credentials), do: []

  @doc "True cuando el panel de miembros de ese lane está expandido."
  def pool_expanded?(expanded, lane_id),
    do: MapSet.member?(expanded || MapSet.new(), lane_id)

  def enabled_badge(true), do: "badge-success"
  def enabled_badge(_), do: "badge-ghost"

  @doc """
  True when the model_provider row sends Fireworks' premium serving path
  (`extra_body["service_tier"] == "priority"`) — powers the Priority badge.
  """
  def service_tier_priority?(%ModelProvider{extra_body: %{"service_tier" => "priority"}}),
    do: true

  def service_tier_priority?(_), do: false

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

  # Un lane de pool está activo si al menos un miembro tiene la credencial
  # activa: el estado del grupo se calcula de sus keys, no del atajo de
  # credencial `nil`.
  def provider_active?(%{pool: %{members: members}}) when is_list(members) do
    Enum.any?(members, fn
      %{credential: %{status: status}} when is_binary(status) -> status == "active"
      _ -> false
    end)
  end

  def provider_active?(%{credential: nil}), do: false

  def provider_active?(%{credential: %{status: status}}) when is_binary(status),
    do: status == "active"

  def provider_active?(_), do: true

  def credential_status_label(%{credential: %{status: "active"}}), do: nil

  def credential_status_label(%{credential: %{status: "disabled"}}),
    do: gettext("disabled credential")

  # El estado de un pool se ve en sus miembros, no en una credencial del lane.
  def credential_status_label(%{pool: %{members: members}}) when is_list(members), do: nil
  def credential_status_label(%{credential: nil}), do: gettext("no credential")
  def credential_status_label(_), do: nil

  # Toggle button title — what the click would do given the effective state.
  @doc false
  def toggle_title(%{enabled: false}), do: gettext("Enable")
  def toggle_title(ap), do: toggle_title_effective(ap)

  defp toggle_title_effective(ap) do
    if provider_active?(ap),
      do: gettext("Disable"),
      else: gettext("Credential disabled — enable it in /catalog/providers")
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
          {@model.name}
          <:subtitle>
            <span class="badge badge-sm badge-outline badge-info">{@model.model_type}</span>
            <span class="text-xs">{format_compact(@model.context_window)} ctx</span>
            <span
              :if={endpoint = type_endpoint(@model.model_type)}
              class="font-mono text-xs text-base-content/40"
            >
              {endpoint}
            </span>
          </:subtitle>
          <:actions>
            <.link navigate={~p"/catalog/models"} class="btn btn-ghost btn-sm" id="back-to-models">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Models")}
            </.link>
            <.button
              phx-click="new_model_provider"
              phx-value-model_id={@model.id}
              id={"new-ap-#{@model.id}"}
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Assign API key")}
            </.button>
          </:actions>
        </.header>

        <div
          :if={@model.guard_rails}
          id="model-guard-rails"
          class="card bg-base-100 border border-base-300 p-4"
        >
          <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
            {gettext("Guard Rails")}
          </h4>
          <p class="text-sm whitespace-pre-line">{@model.guard_rails}</p>
        </div>

        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4">
            <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              {gettext("Served by (API keys)")}
            </h4>
            <div class="overflow-x-auto">
              <.table
                id={"ap-sortable-#{@model.id}"}
                rows={@model_providers}
                row_id={fn ap -> "model-provider-#{ap.id}" end}
                row_class={
                  fn _ap -> ["align-top", @is_admin && "cursor-grab active:cursor-grabbing"] end
                }
                row_attrs={fn ap -> [draggable: to_string(@is_admin), data_id: ap.id] end}
                tbody_hook={if @is_admin, do: "SortableProviders"}
                tbody_model_id={@model.id}
                empty?={Enum.empty?(@model_providers)}
              >
                <:col
                  :let={ap}
                  label={if @is_admin, do: gettext("API key"), else: gettext("Provider")}
                >
                  <.icon
                    :if={@is_admin}
                    name="hero-bars-3"
                    class="w-4 h-4 text-base-content/30 inline-block align-middle mr-1"
                  />
                  <%!-- Rótulo del bloque de scope: `.table` no tiene filas
                       separadoras, así que encabeza la fila que abre el grupo. --%>
                  <p
                    :if={group_label = Map.get(@lane_scope_headers, ap.id)}
                    id={"lane-scope-#{ap.id}"}
                    class="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/50"
                  >
                    {group_label}
                  </p>

                  <%!-- Credential name and key suffix expose internal topology —
                       admins only. Non-admins see just the provider name. --%>
                  <%= cond do %>
                    <% @is_admin && ap.pool -> %>
                      <div class="flex flex-wrap items-center gap-1">
                        <.icon
                          name="hero-rectangle-stack"
                          class="w-3.5 h-3.5 text-base-content/40 shrink-0"
                        />
                        <span class="text-xs font-semibold" id={"pool-name-#{ap.id}"}>
                          {ap.pool.name}
                        </span>
                        <span
                          class="badge badge-xs badge-info font-normal"
                          id={"pool-member-count-#{ap.id}"}
                          title={gettext("API keys in this pool: rotation per request")}
                        >
                          {pool_member_count(ap)} key(s)
                        </span>
                        <span
                          class="badge badge-xs badge-outline font-normal"
                          id={"ap-provider-#{ap.id}"}
                          title={gettext("Provider that owns this API key")}
                        >
                          {provider_name(ap)}
                        </span>
                        <button
                          type="button"
                          phx-click="toggle_pool_members"
                          phx-value-id={ap.id}
                          class="btn btn-xs btn-ghost"
                          id={"pool-members-toggle-#{ap.id}"}
                          title={gettext("Show the API keys in this pool")}
                        >
                          <.icon
                            name={
                              if pool_expanded?(@expanded_pools, ap.id),
                                do: "hero-chevron-up",
                                else: "hero-chevron-down"
                            }
                            class="w-3 h-3"
                          />
                        </button>
                      </div>

                      <%!-- Miembros del pool: el pool sólo aporta keys; la fila
                           conserva prioridad, provider_model y precio. --%>
                      <div
                        :if={pool_expanded?(@expanded_pools, ap.id)}
                        id={"pool-members-#{ap.id}"}
                        class="mt-2 rounded-lg border border-base-300 bg-base-200/40 p-3"
                      >
                        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-2">
                          {gettext("API keys in this pool: rotation per request")}
                        </p>

                        <div class="space-y-1">
                          <div
                            :for={member <- ap.pool.members}
                            id={"pool-member-#{member.id}"}
                            class="flex items-center gap-2"
                          >
                            <span class="font-mono text-xs">{pool_member_label(member)}</span>
                            <span class="text-xs text-base-content/40">
                              {pool_member_mask(member)}
                            </span>
                            <span class={[
                              "badge badge-xs",
                              enabled_badge(pool_member_active?(member))
                            ]}>
                              {enabled_label(pool_member_active?(member))}
                            </span>
                            <button
                              type="button"
                              phx-click="remove_pool_member"
                              phx-value-id={member.id}
                              class="btn btn-xs btn-ghost text-error"
                              id={"remove-pool-member-#{member.id}"}
                              title={gettext("Remove this API key from the pool")}
                            >
                              <.icon name="hero-x-mark" class="w-3 h-3" />
                            </button>
                          </div>
                        </div>

                        <%!-- El alta es su propio form (nunca anidado en otro): es
                             lo que hace que el select viaje con el submit. --%>
                        <form
                          id={"pool-add-form-#{ap.id}"}
                          phx-submit="add_pool_member"
                          class="flex items-center gap-2 mt-3"
                        >
                          <input type="hidden" name="lane_id" value={ap.id} />
                          <select
                            id={"pool-add-member-#{ap.id}"}
                            name="credential_id"
                            class="select select-xs w-72"
                          >
                            <option value="">{gettext("Add an API key…")}</option>
                            <option
                              :for={credential <- pool_add_options(ap.pool, @credentials_for_select)}
                              value={credential.id}
                            >
                              {credential.name || mask_key(credential.api_key_encrypted)}
                            </option>
                          </select>
                          <button
                            type="submit"
                            class="btn btn-xs"
                            id={"pool-add-member-btn-#{ap.id}"}
                          >
                            <.icon name="hero-plus" class="w-3 h-3" /> {gettext("Add")}
                          </button>
                        </form>
                      </div>
                    <% @is_admin && ap.credential -> %>
                      <div class="flex flex-wrap items-center gap-1">
                        <span class="font-mono text-xs">
                          {ap.credential.name || gettext("unnamed key")}
                        </span>
                        <span class="text-xs text-base-content/40">
                          {mask_key(ap.credential.api_key_encrypted)}
                        </span>
                        <%!-- Dueño de la key: la columna «API key» sola no dice a
                             qué proveedor pertenece la key que sirve a este modelo. --%>
                        <span
                          class="badge badge-xs badge-outline font-normal"
                          id={"ap-provider-#{ap.id}"}
                          title={gettext("Provider that owns this API key")}
                        >
                          {provider_name(ap)}
                        </span>
                      </div>
                    <% true -> %>
                      <span class="font-medium">{provider_name(ap)}</span>
                  <% end %>

                  <span
                    :if={service_tier_priority?(ap)}
                    class="badge badge-xs badge-outline font-normal mt-1 badge-warning"
                    title={gettext("Sends service_tier: priority — premium serving path.")}
                  >
                    <.icon name="hero-bolt" class="w-3 h-3" />
                    {gettext("Priority")}
                  </span>
                </:col>
                <:col :let={ap} label={gettext("Model")}>
                  <code class="text-sm">{ap.provider_model}</code>
                </:col>
                <:col :let={ap} label={gettext("Priority")} align="right">
                  <span class="badge badge-xs badge-ghost">{ap.priority || "—"}</span>
                </:col>
                <:col :let={ap} label={gettext("Scope")}>
                  <span class={["badge", "badge-sm", scope_badge(ap)]}>
                    {scope_label(ap)}
                  </span>
                  <span
                    :if={ap.exclusive_to_group_member_id || ap.exclusive_to_group_id}
                    class="text-xs text-base-content/40 ml-1"
                  >
                    {scope_target_label(ap, assigns)}
                  </span>
                </:col>
                <:col :let={ap} label={gettext("Status")}>
                  <span
                    class={["badge", "badge-sm", enabled_badge(provider_active?(ap))]}
                    title={credential_status_label(ap)}
                  >
                    {enabled_label(provider_active?(ap))}
                  </span>
                </:col>
                <:action :let={ap} :if={@is_admin}>
                  <button
                    phx-click="toggle_model_provider"
                    phx-value-id={ap.id}
                    class="btn btn-xs btn-ghost"
                    id={"toggle-ap-#{ap.id}"}
                    title={toggle_title(ap)}
                  >
                    <.icon
                      name={if provider_active?(ap), do: "hero-pause", else: "hero-play"}
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
                </:action>
                <:empty>
                  <div id="lanes-empty">
                    <.icon name="hero-key" class="w-10 h-10 mx-auto mb-2 opacity-40" />
                    <p>{gettext("No API key assigned: nothing can route to it.")}</p>
                  </div>
                </:empty>
              </.table>
            </div>
          </div>
        </div>

        <%!-- Alias provider form (new/edit). Wizard de 3 pasos (credential →
             routing → pricing) sobre el `.modal` único: los tres pasos se
             renderizan SIEMPRE y los inactivos se ocultan con `hidden`, así el
             submit lleva todos los campos y Back no pierde nada. --%>
        <.modal
          :if={@provider_form}
          id="model-provider-modal"
          title={
            if @editing_ap_id == :new,
              do: gettext("Assign provider"),
              else: gettext("Edit provider")
          }
          on_close="cancel_model_provider"
          max_w="max-w-5xl"
          steps={lane_steps()}
          current_step={@lane_step}
        >
          <.form
            for={@provider_form}
            id="model-provider-form"
            phx-submit="save_model_provider"
            phx-change="provider_form_changed"
            phx-window-keydown="close_scope_pickers"
            phx-key="Escape"
          >
            <%!-- Paso 1 — credential: de qué proveedor sale el lane y con qué
                 fuente (una key suelta o un pool) sirve a este modelo. --%>
            <div
              id="lane-step-credential"
              data-step="credential"
              data-active={to_string(@lane_step == "credential")}
              class={["space-y-5", @lane_step != "credential" && "hidden"]}
            >
              <%!-- The provider. When the model came from the catalog this list
                   is exactly the providers that serve it, cheapest first; a
                   custom model falls back to every active provider. --%>
              <div>
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
                      <span
                        :if={
                          provider_key_label(
                            @provider_choices,
                            @provider_credentials,
                            @provider_form_provider_key
                          )
                        }
                        class="text-xs text-base-content/50 font-mono ml-1"
                      >
                        {provider_key_label(
                          @provider_choices,
                          @provider_credentials,
                          @provider_form_provider_key
                        )}
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
                      phx-change="search_providers"
                      id="provider-search"
                      value={@provider_search}
                      placeholder={
                        gettext("Search provider by name or id… (e.g. openrouter, fireworks)")
                      }
                      class="input input-sm w-full pl-9"
                      autocomplete="off"
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
                      phx-value-key={provider_ref(choice.provider)}
                      id={"provider-row-#{dom_key(provider_ref(choice.provider))}"}
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
                        :if={length(choice.provider.credentials) > 0}
                        class="badge badge-xs badge-success shrink-0"
                        title={gettext("It already has API keys registered")}
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

              <%!-- Fuente del lane: una key suelta (el camino de siempre) o un
                     pool de keys del MISMO proveedor, que rota por request. El
                     pool sólo aporta keys: prioridad, modelo y precio siguen
                     siendo del lane. --%>
              <div class="mb-5">
                <label class="text-sm font-medium text-base-content">
                  {gettext("Credential source")}
                </label>
                <p class="text-xs text-base-content/50 mb-2">
                  {gettext(
                    "A pool groups API keys of the same provider and rotates between them on every request."
                  )}
                </p>
                <div class="flex gap-5">
                  <label class="flex items-center gap-2 text-sm cursor-pointer">
                    <input
                      type="radio"
                      id="lane-source-key"
                      name="model_provider[source]"
                      value="key"
                      checked={@lane_source == "key"}
                      class="radio radio-sm"
                    />
                    <.icon name="hero-key" class="w-4 h-4" /> {gettext("One API key")}
                  </label>
                  <label class="flex items-center gap-2 text-sm cursor-pointer">
                    <input
                      type="radio"
                      id="lane-source-pool"
                      name="model_provider[source]"
                      value="pool"
                      checked={@lane_source == "pool"}
                      class="radio radio-sm"
                    />
                    <.icon name="hero-rectangle-stack" class="w-4 h-4" />
                    {gettext("A pool of keys")}
                  </label>
                </div>
              </div>

              <div class="grid md:grid-cols-2 gap-x-8 gap-y-5">
                <div>
                  <%= if @lane_source == "key" do %>
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
                  <% else %>
                    <%!-- Modo pool: el select de pools del proveedor elegido más
                         el alta inline de un pool nuevo con sus miembros. --%>
                    <div class="space-y-2">
                      <div>
                        <label class="text-sm font-medium text-base-content" for="lane-pool-select">
                          {gettext("Pool")}
                        </label>
                        <p class="text-xs text-base-content/50 mb-1">
                          {gettext(
                            "Pools of the selected provider. Every key in the pool rotates on each request."
                          )}
                        </p>
                        <select
                          id="lane-pool-select"
                          name="model_provider[pool_id]"
                          class="select select-sm w-full"
                        >
                          <option value="">{gettext("Pick a pool")}</option>
                          <option
                            :for={pool <- @provider_pools}
                            value={pool.id}
                            selected={@lane_pool_id == pool.id}
                          >
                            {pool.name} ({length(pool.members)} key(s))
                          </option>
                        </select>
                        <div class="flex justify-end">
                          <button
                            type="button"
                            phx-click="delete_pool"
                            phx-value-id={@lane_pool_id || ""}
                            data-confirm={gettext("Delete this pool? This cannot be undone.")}
                            class="btn btn-xs btn-ghost text-error mt-1"
                            id="delete-selected-pool"
                            disabled={is_nil(@lane_pool_id)}
                          >
                            <.icon name="hero-trash" class="w-3 h-3" />
                            {gettext("Delete pool")}
                          </button>
                        </div>
                        <p
                          :if={is_nil(@provider_form_provider_key)}
                          id="pool-needs-provider"
                          class="text-xs text-warning mt-1"
                        >
                          {gettext("Pick the provider the pool belongs to first.")}
                        </p>
                        <p
                          :if={
                            not is_nil(@provider_form_provider_key) and @provider_pools == [] and
                              not @lane_new_pool_open
                          }
                          id="no-pools-hint"
                          class="text-xs text-base-content/50 mt-1"
                        >
                          {gettext("This provider has no pools yet. Create one.")}
                        </p>
                      </div>

                      <button
                        type="button"
                        phx-click="toggle_new_pool"
                        class="btn btn-xs btn-outline"
                        id="new-pool-toggle"
                      >
                        <.icon name="hero-plus" class="w-3 h-3" /> {gettext("New pool")}
                      </button>

                      <div
                        :if={@lane_new_pool_open}
                        id="new-pool-block"
                        class="rounded-lg border border-base-300 p-3 space-y-2"
                      >
                        <div>
                          <label class="text-sm font-medium text-base-content" for="new-pool-name">
                            {gettext("Pool name")}
                          </label>
                          <input
                            type="text"
                            id="new-pool-name"
                            name="model_provider[new_pool_name]"
                            value={@provider_form[:new_pool_name].value}
                            placeholder={gettext("Production keys")}
                            class="input input-sm w-full"
                            autocomplete="off"
                          />
                        </div>
                        <p class="text-xs text-base-content/50">
                          {gettext(
                            "Pick the API keys that become members. All of them must belong to the same provider."
                          )}
                        </p>
                        <div class="max-h-40 overflow-y-auto space-y-1">
                          <label
                            :for={credential <- @provider_credentials || []}
                            class="flex items-center gap-2 text-xs"
                          >
                            <input
                              type="checkbox"
                              id={"new-pool-member-#{credential.id}"}
                              name="model_provider[new_pool_member_ids][]"
                              value={credential.id}
                              checked={new_pool_member_checked?(@provider_form, credential.id)}
                              class="checkbox checkbox-xs"
                            />
                            <span class="font-mono">
                              {credential.name || gettext("unnamed key")}
                            </span>
                            <span class="text-base-content/40">
                              {mask_key(credential.api_key_encrypted)}
                            </span>
                          </label>
                        </div>
                        <p
                          :if={(@provider_credentials || []) == []}
                          class="text-xs text-warning"
                          id="new-pool-no-keys"
                        >
                          {gettext("This provider has no API keys yet.")}
                        </p>
                      </div>
                    </div>
                  <% end %>

                  <p :if={@lane_pool_error} id="lane-pool-error" class="text-xs text-error">
                    {@lane_pool_error}
                  </p>
                </div>

                <%!-- El modelo del upstream que se pide para este lane. Las
                       sugerencias salen del catálogo vivo del proveedor. --%>
                <div>
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
              </div>
            </div>

            <%!-- Paso 2 — routing: alcance (global / perfil de límites / usuario),
                 prioridad y service_tier. Un scope exclusivo exige destino antes
                 de avanzar. --%>
            <div
              id="lane-step-routing"
              data-step="routing"
              data-active={to_string(@lane_step == "routing")}
              class={["space-y-5", @lane_step != "routing" && "hidden"]}
            >
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
                    <label class="text-sm font-medium text-base-content">{gettext("Exclusive user")}</label>
                    <p class="text-xs text-base-content/50 mb-1">
                      <%= if is_new? do %>
                        {gettext(
                          "You can select multiple users. An exclusive provider will be created for each one."
                        )}
                      <% else %>
                        {gettext("Only this user will be able to use this API key for this model.")}
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
                        phx-change="scope_member_search"
                        value={@scope_member_search}
                        placeholder={gettext("Type to search a user…")}
                        phx-focus="open_scope_picker"
                        phx-value-picker="member"
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
                        phx-change="scope_member_search"
                        value={@scope_member_search}
                        placeholder={gettext("Type to search a user…")}
                        phx-focus="open_scope_picker"
                        phx-value-picker="member"
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
                        phx-change="scope_group_search"
                        value={@scope_group_search}
                        placeholder={gettext("Type to search a limit profile…")}
                        phx-focus="open_scope_picker"
                        phx-value-picker="group"
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
                        phx-change="scope_group_search"
                        value={@scope_group_search}
                        placeholder={gettext("Type to search a limit profile…")}
                        phx-focus="open_scope_picker"
                        phx-value-picker="group"
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

              <div class="grid grid-cols-2 gap-3">
                <.input
                  field={@provider_form[:priority]}
                  type="number"
                  label={gettext("Priority")}
                  hint={gettext("Lower = tried first.")}
                />
                <%!-- El sticky es de lanes de UNA key: el router no lo
                     consulta ni lo escribe en un lane de pool (ahí la
                     elección de miembro ocurre después). --%>
                <%= if @lane_source != "pool" do %>
                  <.input
                    field={@provider_form[:sticky_ttl_seconds]}
                    type="number"
                    label={gettext("Sticky TTL (seconds)")}
                    hint={
                      gettext(
                        "Empty uses the config default (180 s / 3 min) for every credential, regardless of billing. If you set a value, that one is always used. Minimum 1 s, maximum 86400 s (24 h). It is stored in milliseconds."
                      )
                    }
                  />
                <% end %>
              </div>

              <%= if @provider_form_is_fireworks do %>
                <div class="space-y-2">
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
                  <p class="text-xs text-base-content/50">
                    <.icon name="hero-bolt" class="w-3.5 h-3.5 inline text-success" />
                    {gettext("Prompt cache:")} <b>{gettext("on by default")}</b>
                    {gettext(
                      "on Fireworks (prefix matching, cached tokens at a discount). TokenGate keeps conversations sticky via the x-session-affinity header and logs the cached tokens — no configuration required."
                    )}
                  </p>
                </div>
              <% end %>

              <.input
                field={@provider_form[:enabled]}
                type="checkbox"
                label={gettext("Enabled for this model")}
                hint={gettext("If it is off, this provider gets no traffic for the model.")}
              />
            </div>

            <%!-- Paso 3 — pricing: la unidad del lane, sus tarifas (condicionales
                 por unidad) y el resumen de los pasos 1-2 antes de guardar. --%>
            <div
              id="lane-step-pricing"
              data-step="pricing"
              data-active={to_string(@lane_step == "pricing")}
              class={["space-y-5", @lane_step != "pricing" && "hidden"]}
            >
              <%!-- El precio se cobra en la unidad que ESTE lane declara. Los
                   tres campos de token sólo tienen sentido cuando la unidad es de
                   tokens; un lane de imagen/tts/stt se cobra por unidad, y sin ese
                   campo quedaba en $0 salvo que el upstream reportara el coste. --%>
              <div class="grid grid-cols-2 gap-3">
                <%!-- Select propio (no `<.input>`) porque necesita su PROPIO
                     phx-change: es lo que conmuta los campos de abajo sin
                     revalidar el form entero (los errores de validación de un
                     form a medio llenar serían ruido). --%>
                <div class="fieldset mb-2">
                  <label class="label" for="ap-pricing-unit">{gettext("Pricing unit")}</label>
                  <select
                    id="ap-pricing-unit"
                    name="model_provider[pricing_unit]"
                    phx-change="pick_pricing_unit"
                    class="select w-full"
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
                <%!-- El rótulo del precio sigue a la UNIDAD del lane: un
                     `per_1k_tokens` cobra USD por 1K, no por 1M. --%>
                <div class={[
                  "grid gap-3",
                  if(cache_write_priced?(@provider_form_provider_key),
                    do: "grid-cols-2 md:grid-cols-4",
                    else: "grid-cols-3"
                  )
                ]}>
                  <.input
                    field={@provider_form[:input_cost_per_million]}
                    type="number"
                    step="0.000001"
                    min="0"
                    label={
                      gettext("Input cost (USD / %{unit})",
                        unit: Pricing.rate_suffix(@provider_form_pricing_unit)
                      )
                    }
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
                    label={
                      gettext("Cache cost (USD / %{unit})",
                        unit: Pricing.rate_suffix(@provider_form_pricing_unit)
                      )
                    }
                    hint={
                      gettext(
                        "Input tokens with a cache hit (cheaper). Empty = use the input price for all of them."
                      )
                    }
                  />
                  <%= if cache_write_priced?(@provider_form_provider_key) do %>
                    <.input
                      field={@provider_form[:cache_write_cost_per_million]}
                      type="number"
                      step="0.000001"
                      min="0"
                      label={
                        gettext("Cache write cost (USD / %{unit})",
                          unit: Pricing.rate_suffix(@provider_form_pricing_unit)
                        )
                      }
                      hint={
                        gettext(
                          "Tokens written into the prompt cache. Only charged when the call reports cache-write tokens; empty = not charged."
                        )
                      }
                    />
                  <% end %>
                  <.input
                    field={@provider_form[:output_cost_per_million]}
                    type="number"
                    step="0.000001"
                    min="0"
                    label={
                      gettext("Output cost (USD / %{unit})",
                        unit: Pricing.rate_suffix(@provider_form_pricing_unit)
                      )
                    }
                    hint={gettext("Output tokens. Same fallback as input.")}
                  />
                </div>
              <% end %>

              <%!-- Resumen de los pasos 1-2: evita guardar un scope o una
                   prioridad que no son los que el operador cree. --%>
              <div
                id="lane-summary"
                class="rounded-lg border border-base-300 bg-base-200/40 p-4 space-y-1 text-sm"
              >
                <p>
                  <span class="text-base-content/50">{gettext("Provider")}:</span>
                  <span class="font-medium">{lane_summary_provider(assigns)}</span>
                </p>
                <p>
                  <span class="text-base-content/50">{gettext("Credential (API key)")}:</span>
                  <span class="font-medium">{lane_summary_credential(assigns)}</span>
                </p>
                <p>
                  <span class="text-base-content/50">{gettext("Provider model")}:</span>
                  <code class="text-xs">{@provider_form[:provider_model].value || "—"}</code>
                </p>
                <p>
                  <span class="text-base-content/50">{gettext("Scope")}:</span>
                  <span class="font-medium">{lane_summary_scope(assigns)}</span>
                </p>
                <p>
                  <span class="text-base-content/50">{gettext("Priority")}:</span>
                  <span class="font-medium">{@provider_form[:priority].value || "—"}</span>
                </p>
                <p>
                  <span class="text-base-content/50">{gettext("Status")}:</span>
                  <span class="font-medium">{enabled_label(@provider_form[:enabled].value == true)}</span>
                </p>
              </div>
            </div>

            <p
              :if={@lane_step_error}
              id="lane-step-error"
              role="alert"
              class="mt-4 text-xs text-error"
            >
              {@lane_step_error}
            </p>
          </.form>

          <%!-- Inline API-key form. It is a SIBLING of the model_provider
               form, never nested (a form inside a form is dropped by the
               browser and the key could never be submitted). Creating the key
               here leaves it selected, so the model is one click from
               routable. It only shows on the credential step, but stays
               mounted (hidden) so typing survives Back/Next. --%>
          <%= if @credential_form do %>
            <div
              class={[
                "mt-5 p-4 rounded-lg border border-primary/40 bg-primary/5",
                @lane_step != "credential" && "hidden"
              ]}
              id="inline-credential-form"
            >
              <h3 class="text-sm font-semibold mb-1">
                {gettext("New API key")}
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

          <:footer>
            <button
              :if={@lane_step != "credential"}
              type="button"
              phx-click="lane_prev_step"
              class="btn btn-ghost btn-sm"
              id="lane-back-btn"
            >
              {gettext("Back")}
            </button>
            <button
              :if={@lane_step != "pricing"}
              type="button"
              phx-click="lane_next_step"
              class="btn btn-primary btn-sm"
              id="lane-next-btn"
            >
              {gettext("Next")}
            </button>
            <button
              :if={@lane_step == "pricing"}
              type="submit"
              form="model-provider-form"
              class="btn btn-primary btn-sm"
              id="save-ap-btn"
            >
              {gettext("Save")}
            </button>
          </:footer>
        </.modal>
      </div>
    </Layouts.dashboard>
    """
  end
end
