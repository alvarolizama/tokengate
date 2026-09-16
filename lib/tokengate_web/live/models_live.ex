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
  serves as a fallback when the upstream omits cost. Billing is a
  provider-level attribute (`providers.billing_type`): an organizational
  label for grouping providers, with no effect on cost. Every provider is
  priced by the same chain (upstream report → manual pricing → $0).
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
  alias Tokengate.Providers.{Model, ModelProvider}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = user && user.global_role == "admin"

    socket =
      socket
      |> assign(:page_title, "Modelos · Tokengate")
      |> assign(:is_admin, is_admin)
      |> assign(:model_type_filter, "favorites")
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
      |> assign(:current_scope, "global")
      |> assign(:current_scope_group_ids, [])
      |> assign(:current_scope_member_ids, [])
      |> assign(:scope_group_search, "")
      |> assign(:scope_member_search, "")
      |> assign(:scope_group_open, false)
      |> assign(:scope_member_open, false)
      |> load_models()
      |> assign_form_data()
      |> load_scope_data()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_models(socket) do
    filter = socket.assigns.model_type_filter

    models =
      aliases_with_providers_query()
      |> Repo.all()
      |> filter_by_type(filter)

    socket
    |> stream(:models, models, reset: true)
    |> assign(:models_empty?, models == [])
  end

  defp filter_by_type(models, "all"), do: models
  defp filter_by_type(models, "favorites"), do: Enum.filter(models, & &1.pinned)
  defp filter_by_type(models, type), do: Enum.filter(models, &(&1.model_type == type))

  # The model_type of the model being edited (edit_model_provider path).
  defp get_alias_type(_socket, model_id) do
    case Tokengate.Repo.get(Tokengate.Providers.Model, model_id) do
      nil -> "llm"
      model_ -> model_.model_type || "llm"
    end
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
  def handle_event("new_model", _params, socket) do
    if socket.assigns.is_admin do
      changeset = Providers.change_model(%Model{})

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model))
       |> assign(:editing_model_id, :new)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_model_id, nil)}
  end

  def handle_event("filter_model_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:model_type_filter, type)
     |> load_models()}
  end

  def handle_event("toggle_pin", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      model = Providers.get_model!(model_id)
      new_pinned = !model.pinned

      case Providers.update_model(model, %{pinned: new_pinned}) do
        {:ok, _updated} ->
          {:noreply, load_models(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el modelo.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
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
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
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
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("edit_model", %{"id" => model_id}, socket) do
    if socket.assigns.is_admin do
      model = Providers.get_model!(model_id)
      changeset = Providers.change_model(model)

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model))
       |> assign(:editing_model_id, model.id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("save_model", %{"model" => model_params}, socket) do
    if socket.assigns.is_admin do
      save_model(socket, socket.assigns.editing_model_id, model_params)
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
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
           "No se puede eliminar: el modelo tiene proveedores asignados. Elimínalos primero."
         )}
      else
        case Providers.delete_model(model_record) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Modelo eliminado.")
             |> load_models()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo eliminar el modelo.")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Events — model_provider management -------------------------------------

  def handle_event("new_model_provider", %{"model_id" => model_id}, socket) do
    if socket.assigns.is_admin do
      changeset =
        Providers.change_model_provider(%ModelProvider{
          model_id: model_id,
          enabled: true,
          # Sensible default: cache_control on (Fireworks overrides this to
          # false at save time — apply_provider_defaults).
          cache_control_enabled: true
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
       |> assign(:scope_member_open, false)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
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

      # Prefill the service_tier checkbox from the stored extra_body (the
      # raw override virtuals are no longer part of the form).
      changeset =
        Ecto.Changeset.put_change(
          changeset,
          :service_tier_priority,
          Map.get(ap.extra_body || %{}, "service_tier") == "priority"
        )

      {:noreply,
       socket
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, ap.id)
       |> assign(:provider_form_credential_id, ap.credential_id)
       |> assign(:provider_form_is_fireworks, credential_is_fireworks?(ap.credential_id, socket))
       |> assign(:current_scope, scope)
       |> assign(:current_scope_group_id, ap.exclusive_to_group_id)
       |> assign(:current_scope_member_id, ap.exclusive_to_group_member_id)
       |> assign(:scope_group_search, group_label)
       |> assign(:scope_member_search, member_label)
       |> assign(:provider_models_loading, true)
       |> fetch_provider_models(ap.credential_id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

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
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
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
        credential_id == "" or credential_id == nil ->
          {:noreply, assign(socket, :provider_models, [])}

        credential_id != socket.assigns[:provider_form_credential_id] ->
          {:noreply,
           socket
           |> assign(:provider_form_credential_id, credential_id)
           |> assign(:provider_form_is_fireworks, credential_is_fireworks?(credential_id, socket))
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
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Proveedor #{if new_enabled, do: "activado", else: "desactivado"}."
           )
           |> load_models()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo actualizar el proveedor.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("delete_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)

      case Providers.delete_model_provider(ap) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Proveedor eliminado del modelo.")
           |> load_models()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo eliminar el proveedor.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
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

        {:noreply, load_models(socket)}
      else
        {:noreply, put_flash(socket, :error, "Orden inválido para este modelo.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Private helpers — model save ------------------------------------------

  defp save_model(socket, :new, model_params) do
    case Providers.create_model(model_params) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> put_flash(:info, "Modelo creado.")
         |> assign(:form, nil)
         |> assign(:editing_model_id, nil)
         |> load_models()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model))}
    end
  end

  defp save_model(socket, model_id, model_params) when is_binary(model_id) do
    model_record = Providers.get_model!(model_id)

    case Providers.update_model(model_record, model_params) do
      {:ok, _model} ->
        {:noreply,
         socket
         |> put_flash(:info, "Modelo actualizado.")
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

      # Which catalogue to list depends on the model being edited: the
      # active filter when creating, the edited model's type otherwise.
      model_type =
        case socket.assigns.editing_model_id do
          :new -> socket.assigns.model_type_filter
          nil -> socket.assigns.model_type_filter
          id -> get_alias_type(socket, id)
        end

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
           |> put_flash(:error, "No se pudieron cargar los models del proveedor.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  # Per-provider defaults applied on every save (create and edit). The form
  # no longer surfaces raw overrides; this keeps the stored columns coherent:
  #
  #   * cache_control_enabled — TRUE by default (good for every upstream that
  #     honors Anthropic-style breakpoints); FALSE and forced off for
  #     Fireworks, which rejects the content-parts format with a 400.
  #   * extra_body / omit_* — the UI can't set them anymore (schema fields
  #     stay for programmatic use); only the service_tier checkbox writes
  #     extra_body, via the changeset.
  defp apply_provider_defaults(ap_params, socket) do
    # Derive the provider from the credential being saved — NOT from the
    # form-change assign (a direct submit without a prior change event never
    # fires provider_form_changed and the assign stays stale).
    credential_id = Map.get(ap_params, "credential_id")
    fireworks? = credential_is_fireworks?(credential_id, socket)

    ap_params
    |> Map.put("cache_control_enabled", not fireworks?)
    |> Map.drop(["extra_body_json", "omit_body_fields_csv", "omit_headers_csv"])
  end

  defp save_model_provider(socket, :new, ap_params) do
    ap_params = Map.put(ap_params, "model_id", socket.assigns.provider_form_model_id)

    # Per-provider defaults the form no longer asks for: cache_control on
    # except Fireworks (it rejects the content-parts format with a 400), and
    # the raw extra_body override is not submittable from the UI anymore —
    # the service_tier checkbox owns extra_body's only managed key.
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
           "Selecciona al menos un grupo o usuario para el scope exclusivo."
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
                do: "Proveedor asignado al modelo.",
                else: "#{count} proveedores asignados al modelo."

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
               "No se pudo asignar: #{Enum.map_join(changeset.errors, ", ", fn {_f, {m, _}} -> m end)}"
             )
             |> assign(:provider_form, to_form(changeset, as: :model_provider))}
        end
    end
  end

  defp save_model_provider(socket, ap_id, ap_params) when is_binary(ap_id) do
    ap = Providers.get_model_provider!(ap_id)
    ap_params = apply_provider_defaults(ap_params, socket)

    case Providers.update_model_provider(ap, ap_params) do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor actualizado.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_models()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :model_provider))}
    end
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
  Format a market price compactly for the model card row: trims trailing
  zeros ("1.250000" -> "1.25"). Display-only. Deliberately avoids
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

  @doc "True when at least one market price is set (Decimals may be nil)."
  def has_market_prices?(model) do
    not is_nil(model.market_input_price_per_1m) or
      not is_nil(model.market_output_price_per_1m) or
      not is_nil(model.market_cache_price_per_1m)
  end

  @doc """
  Full market-price line for the model card row. Built as ONE string in
  Elixir so HEEx cannot inject whitespace between "$" and the value.
  """
  def market_line(model) do
    "· in $" <>
      fmt_price(model.market_input_price_per_1m) <>
      " · out $" <>
      fmt_price(model.market_output_price_per_1m) <>
      " · cache $" <> fmt_price(model.market_cache_price_per_1m) <> " /1M"
  end

  @doc "Empty-state message for the active model type filter"
  def empty_state_message("favorites"),
    do: "No hay modelos pineados. Pinea un modelo para verlo aquí."

  def empty_state_message("all"), do: "No hay models configurados."
  def empty_state_message("llm"), do: "No hay models LLM."
  def empty_state_message("embedding"), do: "No hay models de embedding."
  def empty_state_message(_), do: "No hay models configurados."

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
    do: "Exclusivo miembro"

  def scope_label(%ModelProvider{exclusive_to_group_id: id}) when not is_nil(id),
    do: "Exclusivo grupo"

  def scope_label(%ModelProvider{}), do: "Global"
  def scope_label("member"), do: "Exclusivo miembro"
  def scope_label("group"), do: "Exclusivo grupo"
  def scope_label(_), do: "Global"

  @doc "Resolve scope to human-readable label with target name"
  def scope_target_label(%ModelProvider{} = mp, assigns) do
    cond do
      mp.exclusive_to_group_member_id ->
        member =
          Enum.find(assigns.members_for_select || [], &(&1.id == mp.exclusive_to_group_member_id))

        if member && member.user, do: member.user.email, else: "Miembro"

      mp.exclusive_to_group_id ->
        group = Enum.find(assigns.groups_for_select || [], &(&1.id == mp.exclusive_to_group_id))
        if group, do: group.name, else: "Grupo"

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
  def scope_group_label(1), do: "Exclusivos por grupo"
  def scope_group_label(2), do: "Exclusivos por usuario"
  def scope_group_label(_), do: nil

  def provider_name(%ModelProvider{credential: %{provider: provider}}) when not is_nil(provider),
    do: provider.name

  def provider_name(_), do: "—"

  def credential_named?(%{name: name}) when is_binary(name) and name != "", do: true
  def credential_named?(_), do: false

  def billing_badge("subscription"), do: "badge-success"
  def billing_badge(_), do: "badge-ghost"

  def billing_label("subscription"), do: "Suscripción"
  def billing_label(_), do: "Pay per token"

  # Billing surface of the model_provider's provider — an organizational
  # label only (it does not drive routing, cost or budget anymore). It is a
  # CATALOG label: only a builtin has an upstream surface to name, so a custom
  # provider has none and the badge is skipped (nil). Falls back to nil when
  # the association isn't loaded.
  defp provider_billing_type(%ModelProvider{
         credential: %{provider: %{source: "builtin", billing_type: type}}
       })
       when is_binary(type),
       do: type

  defp provider_billing_type(_), do: nil

  def enabled_badge(true), do: "badge-success"
  def enabled_badge(_), do: "badge-ghost"

  def enabled_label(true), do: "Activo"
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
  def credential_status_label(%{credential: nil}), do: "sin credential"
  def credential_status_label(_), do: nil

  # Toggle button title — what the click would do given the effective state.
  @doc false
  def toggle_title(%{enabled: false}), do: "Activar"
  def toggle_title(ap), do: toggle_title_effective(ap)

  defp toggle_title_effective(ap) do
    if provider_active?(ap),
      do: "Desactivar",
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
          Modelos
          <:subtitle>Configura models y sus proveedores de routing</:subtitle>
          <:actions :if={@is_admin}>
            <.button phx-click="new_model" id="new-model-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo Modelo
            </.button>
          </:actions>
        </.header>

        <%!-- Model type filter tabs --%>
        <div class="join" id="model-type-tabs" role="tablist">
          <button
            :for={
              {label, value} <- [
                {"Favoritos", "favorites"},
                {"LLM", "llm"},
                {"Embedding", "embedding"},
                {"Todos", "all"}
              ]
            }
            phx-click="filter_model_type"
            phx-value-type={value}
            class={[
              "join-item btn btn-sm",
              if(@model_type_filter == value, do: "btn-primary", else: "btn-ghost")
            ]}
            id={"model-type-#{value}"}
          >
            {label}
          </button>
        </div>

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
          <p>{empty_state_message(@model_type_filter)}</p>
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
                    title="Expandir / colapsar proveedores"
                  >
                    <div class="flex items-center gap-2 flex-wrap">
                      <span
                        id={"model-chevron-#{model.id}"}
                        class="text-base-content/40 transition-transform"
                      >
                        <.icon name="hero-chevron-right" class="w-4 h-4" />
                      </span>
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
                        :if={has_market_prices?(model)}
                        class="text-xs text-base-content/50 tabular-nums"
                        title="Precio de mercado de referencia (informativo — no se usa para facturación)"
                      >
                        {market_line(model)}
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
                        title={if model.pinned, do: "Quitar pin", else: "Pinear al inicio"}
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
                        data-confirm="¿Eliminar este modelo? Esta acción no se puede deshacer."
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
                      Proveedores asignados
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
                    No hay proveedores asignados.
                  </div>

                  <div :if={model_providers_for(model) != []} class="overflow-x-auto">
                    <table class="table table-sm table-fixed w-full">
                      <thead>
                        <tr>
                          <th :if={@is_admin} class="w-8" title="Arrastra para reordenar prioridad">
                          </th>
                          <th>Proveedor</th>
                          <th>Modelo</th>
                          <th>Facturación</th>
                          <th>Prioridad</th>
                          <th>Scope</th>
                          <th>Estado</th>
                          <%= if @is_admin do %>
                            <th>Acciones</th>
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
                                colspan={if @is_admin, do: "8", else: "6"}
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
                              <span
                                :if={provider_billing_type(ap)}
                                class={[
                                  "badge",
                                  "badge-sm",
                                  billing_badge(provider_billing_type(ap))
                                ]}
                              >
                                {billing_label(provider_billing_type(ap))}
                              </span>
                            </td>
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
                                    data-confirm="¿Eliminar este proveedor del modelo?"
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

        <%!-- Alias form (new/edit) --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-3xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_model_id == :new, do: "Nuevo Modelo", else: "Editar Modelo"}
              </h2>

              <.form for={@form} id="model-form" phx-submit="save_model">
                <div class="grid md:grid-cols-2 gap-x-8 gap-y-1">
                  <div>
                    <.input
                      field={@form[:name]}
                      type="text"
                      label="Nombre (identificador)"
                      required
                      hint="Nombre interno del modelo, ej. gpt-4o. Debe ser único."
                    />
                    <.input
                      field={@form[:model_type]}
                      type="select"
                      label="Tipo de modelo"
                      options={[
                        {"LLM (chat)", "llm"},
                        {"Embedding", "embedding"}
                      ]}
                      hint="Define qué endpoint lo sirve: /v1/chat/completions o /v1/embeddings."
                    />

                    <div class="divider my-2 text-xs text-base-content/50">
                      Precio de mercado de referencia (informativo)
                    </div>
                    <%!--
                      Display-only market prices: they document what the
                      model roughly costs per 1M tokens. They are NOT used by
                      the cost engine — billing comes from upstream-reported
                      usage or the provider's manual fallback rates.
                    --%>
                    <div class="grid grid-cols-3 gap-2">
                      <.input
                        field={@form[:market_input_price_per_1m]}
                        type="number"
                        step="0.000001"
                        min="0"
                        label="Entrada $/1M"
                      />
                      <.input
                        field={@form[:market_output_price_per_1m]}
                        type="number"
                        step="0.000001"
                        min="0"
                        label="Salida $/1M"
                      />
                      <.input
                        field={@form[:market_cache_price_per_1m]}
                        type="number"
                        step="0.000001"
                        min="0"
                        label="Cache $/1M"
                      />
                    </div>
                  </div>

                  <div class="space-y-1">
                    <.input
                      field={@form[:context_window]}
                      type="number"
                      label="Ventana de contexto (tokens)"
                      required
                      hint="Tamaño máximo de contexto del modelo en tokens."
                    />
                  </div>
                </div>

                <div class="md:col-span-2 flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-model-btn">
                    Guardar
                  </button>
                </div>
              </.form>
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
                Texto que se inyecta al inicio de cada system prompt enviado al proveedor.
                Úsalo para instrucciones de comportamiento, límites de contenido, o reglas de formato.
              </p>

              <.form for={@guard_rails_form} id="guard-rails-form" phx-submit="save_guard_rails">
                <.input
                  field={@guard_rails_form[:guard_rails]}
                  type="textarea"
                  label="Instrucciones de sistema (guard rails)"
                  rows="8"
                  placeholder="Ej: Responde siempre en español. No uses markdown. Sé conciso..."
                  hint="Este texto se antepone al system prompt del usuario. Déjalo vacío para no inyectar nada."
                />

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_guard_rails" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-guard-rails-btn">
                    Guardar
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
                {if @editing_ap_id == :new, do: "Asignar Proveedor", else: "Editar Proveedor"}
              </h2>

              <.form
                for={@provider_form}
                id="model-provider-form"
                phx-submit="save_model_provider"
                phx-change="provider_form_changed"
                phx-window-keydown="close_scope_pickers"
                phx-key="Escape"
              >
                <div class="grid md:grid-cols-2 gap-x-8 gap-y-5">
                  <div>
                    <.input
                      field={@provider_form[:credential_id]}
                      type="select"
                      label="Credencial (API Key)"
                      options={credential_options(@credentials_for_select)}
                      prompt="Selecciona una credencial"
                      required
                      hint="La API key específica que servirá este modelo. Cada credencial tiene su propio circuit breaker y prioridad."
                    />

                    <%= if @provider_models_loading do %>
                      <div class="flex items-center gap-2 text-sm text-base-content/50 py-2">
                        <span class="loading loading-spinner loading-xs"></span>
                        Cargando models del proveedor…
                      </div>
                    <% end %>

                    <.input
                      field={@provider_form[:provider_model]}
                      type="text"
                      label="Modelo del proveedor"
                      required
                      placeholder="Escribe o selecciona el modelo (ej. glm-5.2:dedicated)"
                      hint="Sugerencias del catálogo del proveedor. Puedes escribir cualquier valor para tiers dedicados o privados."
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
                      <label class="text-sm font-medium text-base-content">Alcance (Scope)</label>
                      <p class="text-xs text-base-content/50 mb-2">
                        Global = todos los miembros con acceso. Exclusivo = solo el miembro o grupo seleccionado.
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
                          <.icon name="hero-users" class="w-4 h-4" /> Grupo
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
                        <label class="text-sm font-medium text-base-content">Usuario exclusivo</label>
                        <p class="text-xs text-base-content/50 mb-1">
                          <%= if is_new? do %>
                            Puedes seleccionar múltiples usuarios. Se creará un proveedor exclusivo por cada uno.
                          <% else %>
                            Solo este usuario podrá usar esta API key para este modelo.
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
                            placeholder="Escribe para buscar usuario…"
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
                            placeholder="Escribe para buscar usuario…"
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
                                  (actual)
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
                        <label class="text-sm font-medium text-base-content">Grupo exclusivo</label>
                        <p class="text-xs text-base-content/50 mb-1">
                          <%= if is_new? do %>
                            Puedes seleccionar múltiples grupos. Se creará un proveedor exclusivo por cada uno.
                          <% else %>
                            Solo los miembros de este grupo podrán usar esta API key para este modelo.
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
                            placeholder="Escribe para buscar grupo…"
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
                            placeholder="Escribe para buscar grupo…"
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
                                  (actual)
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
                        hint="Vacío usa el default de config (180 s / 3 min) para toda credencial, sin importar la facturación. Si pones un valor, siempre se usa ese. Mínimo 1 s, máximo 86 400 s (24 h). Se guarda en milisegundos."
                      />
                    </div>

                    <div class="grid grid-cols-3 gap-3">
                      <.input
                        field={@provider_form[:input_cost_per_million]}
                        type="number"
                        step="0.000001"
                        min="0"
                        label="Costo input (USD / 1M)"
                        hint="Tokens de entrada no-caché. Fallback cuando el proveedor no reporta costo."
                      />
                      <.input
                        field={@provider_form[:cache_cost_per_million]}
                        type="number"
                        step="0.000001"
                        min="0"
                        label="Costo cache (USD / 1M)"
                        hint="Tokens de entrada con cache hit (más barato). Vacío = usa precio de input para todos."
                      />
                      <.input
                        field={@provider_form[:output_cost_per_million]}
                        type="number"
                        step="0.000001"
                        min="0"
                        label="Costo output (USD / 1M)"
                        hint="Tokens de salida. Mismo fallback que input."
                      />
                    </div>

                    <%= if @provider_form_is_fireworks do %>
                      <%!-- Fireworks: la configuración de caché es automática
                           (prefix match por defecto) y valida el body con
                           estrictez — el cache_control explícito (estilo
                           Anthropic) le rompe el request (400: exige content
                           string). Solo se muestra lo que le aplica. --%>
                      <.input
                        field={@provider_form[:service_tier_priority]}
                        type="checkbox"
                        label="Fireworks Priority (service_tier)"
                        hint="Manda service_tier: priority — mayor confiabilidad en horas pico, se cobra a premium según el modelo."
                      />
                      <p class="text-xs text-base-content/50 -mt-2">
                        <.icon name="hero-bolt" class="w-3.5 h-3.5 inline text-success" />
                        Caché de prompts: <b>activa por defecto</b>
                        en Fireworks (coincidencia de prefijo, tokens cacheados a descuento). TokenGate ya manda
                        prompt_cache_key + x-session-affinity por conversación y registra los tokens cacheados en los logs — no requiere configuración.
                      </p>
                    <% else %>
                      <.input
                        field={@provider_form[:cache_control_enabled]}
                        type="checkbox"
                        label="Inyectar cache_control explícito"
                        hint="Marca el prefijo system con un breakpoint ephemeral estilo Anthropic. Solo para upstreams que lo honoran (Anthropic, z.ai, OpenRouter). Lecturas de caché hasta −90%. Viene activado por defecto."
                      />
                    <% end %>

                    <.input
                      field={@provider_form[:enabled]}
                      type="checkbox"
                      label="Habilitado"
                      hint="Si está apagado, este provider no recibe tráfico del modelo."
                    />
                  </div>
                </div>

                <div class="md:col-span-2 flex gap-2 pt-4 mt-5 border-t border-base-200 justify-end">
                  <button type="button" phx-click="cancel_model_provider" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-ap-btn">
                    Guardar
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
