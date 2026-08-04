defmodule TokengateWeb.ModelsLive do
  @moduledoc """
  CRUD for model_aliases + per-model model_provider management.

  Admins can create, edit, and delete models, and assign providers to each
  model (provider_model, priority, enabled toggle, billing_mode, scope).
  Managers and regular users see a read-only list.

  Models are global. Admins can create, edit, and delete models,
  and assign providers to each model.

  ## Cost model (2026-07-30)

  Since we trust the upstream to report what it actually charged via
  `usage.cost`, there is no per-provider pricing form anymore. The only
  cost-relevant attribute on a model_provider is `billing_mode`:
  `"pay_per_token"` or `"included"` (subscription / RPM-limited).

  ## Exclusive scope

  A model_provider can be scoped to serve only specific consumers:
    * Global — available to all team members with access.
    * Member-exclusive — only the specified team member sees it.
    * Team-exclusive — only members of the specified team see it.
  """
  use TokengateWeb, :live_view

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Accounts
  alias Tokengate.Providers
  alias Tokengate.Providers.{ModelAlias, ModelProvider}
  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    is_admin = user && user.global_role == "admin"

    socket =
      socket
      |> assign(:page_title, "Modelos · Tokengate")
      |> assign(:is_admin, is_admin)
      |> assign(:form, nil)
      |> assign(:editing_alias_id, nil)
      |> assign(:guard_rails_form, nil)
      |> assign(:guard_rails_alias_id, nil)
      |> assign(:provider_form, nil)
      |> assign(:provider_form_alias_id, nil)
      |> assign(:editing_ap_id, nil)
      |> assign(:provider_models, [])
      |> assign(:provider_models_loading, false)
      |> assign(:provider_model_search, "")
      |> assign(:provider_form_credential_id, nil)
      |> assign(:current_billing_mode, "pay_per_token")
      |> assign(:current_scope, "global")
      |> assign(:current_scope_team_id, nil)
      |> assign(:current_scope_member_id, nil)
      |> assign(:scope_team_search, "")
      |> assign(:scope_member_search, "")
      |> assign(:scope_team_open, false)
      |> assign(:scope_member_open, false)
      |> load_aliases()
      |> assign_form_data()
      |> load_scope_data()

    {:ok, socket}
  end

  ## Data loading ---------------------------------------------------------

  defp load_aliases(socket) do
    # Providers are grouped by scope first — global, then team-exclusive,
    # then member-exclusive — and ordered by priority within each group.
    aliases =
      from(ma in ModelAlias,
        left_join: aps in assoc(ma, :model_providers),
        preload: [model_providers: {aps, [credential: :provider]}],
        order_by: [
          asc: ma.name,
          asc:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN 2 WHEN ? IS NOT NULL THEN 1 ELSE 0 END",
              aps.exclusive_to_team_member_id,
              aps.exclusive_to_team_id
            ),
          asc_nulls_last: aps.priority
        ]
      )
      |> Repo.all()

    socket
    |> stream(:aliases, aliases, reset: true)
    |> assign(:aliases_empty?, aliases == [])
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
    teams = Accounts.list_teams()

    members =
      from(tm in Tokengate.Accounts.TeamMember,
        preload: [:user],
        order_by: [asc: tm.id]
      )
      |> Repo.all()

    socket
    |> assign(:teams_for_select, teams)
    |> assign(:members_for_select, members)
  end

  ## Events — alias CRUD ---------------------------------------------------

  @impl true
  def handle_event("new_alias", _params, socket) do
    if socket.assigns.is_admin do
      changeset = Providers.change_model_alias(%ModelAlias{})

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model_alias))
       |> assign(:editing_alias_id, :new)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_alias_id, nil)}
  end

  def handle_event("edit_guard_rails", %{"id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      model_alias = Providers.get_model_alias!(alias_id)
      changeset = Providers.change_model_alias(model_alias)

      {:noreply,
       socket
       |> assign(:guard_rails_form, to_form(changeset, as: :model_alias))
       |> assign(:guard_rails_alias_id, model_alias.id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("cancel_guard_rails", _params, socket) do
    {:noreply,
     socket
     |> assign(:guard_rails_form, nil)
     |> assign(:guard_rails_alias_id, nil)}
  end

  def handle_event("save_guard_rails", %{"model_alias" => alias_params}, socket) do
    if socket.assigns.is_admin do
      model_alias = Providers.get_model_alias!(socket.assigns.guard_rails_alias_id)

      case Providers.update_model_alias(model_alias, alias_params) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Guard rails actualizados.")
           |> assign(:guard_rails_form, nil)
           |> assign(:guard_rails_alias_id, nil)
           |> load_aliases()}

        {:error, changeset} ->
          {:noreply, assign(socket, :guard_rails_form, to_form(changeset, as: :model_alias))}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("edit_alias", %{"id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      model_alias = Providers.get_model_alias!(alias_id)
      changeset = Providers.change_model_alias(model_alias)

      {:noreply,
       socket
       |> assign(:form, to_form(changeset, as: :model_alias))
       |> assign(:editing_alias_id, model_alias.id)}
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("save_alias", %{"model_alias" => alias_params}, socket) do
    if socket.assigns.is_admin do
      save_alias(socket, socket.assigns.editing_alias_id, alias_params)
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("delete_alias", %{"id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      alias_record = Providers.get_model_alias!(alias_id)

      has_providers? =
        Repo.exists?(from(ap in ModelProvider, where: ap.model_alias_id == ^alias_id))

      if has_providers? do
        {:noreply,
         put_flash(
           socket,
           :error,
           "No se puede eliminar: el modelo tiene proveedores asignados. Elimínalos primero."
         )}
      else
        case Providers.delete_model_alias(alias_record) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Modelo eliminado.")
             |> load_aliases()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "No se pudo eliminar el modelo.")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Events — model_provider management -------------------------------------

  def handle_event("new_model_provider", %{"alias_id" => alias_id}, socket) do
    if socket.assigns.is_admin do
      changeset =
        Providers.change_model_provider(%ModelProvider{
          model_alias_id: alias_id,
          enabled: true
        })

      {:noreply,
       socket
       |> assign(:provider_form_alias_id, alias_id)
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, :new)
       |> assign(:current_scope, "global")
       |> assign(:current_scope_team_id, nil)
       |> assign(:current_scope_member_id, nil)
       |> assign(:scope_team_search, "")
       |> assign(:scope_member_search, "")
       |> assign(:scope_team_open, false)
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
     |> assign(:current_billing_mode, "pay_per_token")
     |> assign(:current_scope, "global")
     |> assign(:current_scope_team_id, nil)
     |> assign(:current_scope_member_id, nil)
     |> assign(:scope_team_search, "")
     |> assign(:scope_member_search, "")
     |> assign(:scope_team_open, false)
     |> assign(:scope_member_open, false)}
  end

  def handle_event("edit_model_provider", %{"id" => ap_id}, socket) do
    if socket.assigns.is_admin do
      ap = Providers.get_model_provider!(ap_id)
      changeset = Providers.change_model_provider(ap)

      scope =
        cond do
          ap.exclusive_to_team_member_id != nil -> "member"
          ap.exclusive_to_team_id != nil -> "team"
          true -> "global"
        end

      # Prefill the search inputs with the current selection's label so the
      # user sees which team / member is bound to the provider.
      team_label =
        if ap.exclusive_to_team_id do
          team =
            Enum.find(socket.assigns.teams_for_select || [], &(&1.id == ap.exclusive_to_team_id))

          if team, do: team.name, else: ""
        else
          ""
        end

      member_label =
        if ap.exclusive_to_team_member_id do
          member =
            Enum.find(
              socket.assigns.members_for_select || [],
              &(&1.id == ap.exclusive_to_team_member_id)
            )

          if member && member.user, do: member.user.email, else: ""
        else
          ""
        end

      {:noreply,
       socket
       |> assign(:provider_form, to_form(changeset, as: :model_provider))
       |> assign(:editing_ap_id, ap.id)
       |> assign(:provider_form_credential_id, ap.credential_id)
       |> assign(:current_billing_mode, ap.billing_mode || "pay_per_token")
       |> assign(:current_scope, scope)
       |> assign(:current_scope_team_id, ap.exclusive_to_team_id)
       |> assign(:current_scope_member_id, ap.exclusive_to_team_member_id)
       |> assign(:scope_team_search, team_label)
       |> assign(:scope_member_search, member_label)
       # Open the dropdowns in edit mode so the admin can re-pick without
       # having to clear the field first. The pre-filled label acts as the
       # current selection — it's not "missing autocomplete", it's already
       # there; we just expose the rest of the list.
       |> assign(:scope_team_open, scope == "team")
       |> assign(:scope_member_open, scope == "member")
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

      billing_mode =
        ap_params["billing_mode"] || socket.assigns[:current_billing_mode] || "pay_per_token"

      socket =
        socket
        |> assign(:current_billing_mode, billing_mode)
        |> assign(:provider_model_search, model_search)

      cond do
        credential_id == "" or credential_id == nil ->
          {:noreply, assign(socket, :provider_models, [])}

        credential_id != socket.assigns[:provider_form_credential_id] ->
          {:noreply,
           socket
           |> assign(:provider_form_credential_id, credential_id)
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
       |> assign(:current_scope_team_id, nil)
       |> assign(:current_scope_member_id, nil)
       |> assign(:scope_team_search, "")
       |> assign(:scope_member_search, "")
       |> assign(:scope_team_open, false)
       |> assign(:scope_member_open, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_scope_member", %{"member_id" => member_id}, socket) do
    if socket.assigns.is_admin do
      {:noreply, assign(socket, :current_scope_member_id, member_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_scope_team", %{"team_id" => team_id}, socket) do
    if socket.assigns.is_admin do
      {:noreply, assign(socket, :current_scope_team_id, team_id)}
    else
      {:noreply, socket}
    end
  end

  # Handle select change events from the scope dropdowns
  def handle_event(
        "select_scope_member",
        %{"model_provider" => %{"scope_member_id" => member_id}},
        socket
      ) do
    if socket.assigns.is_admin do
      {:noreply, assign(socket, :current_scope_member_id, member_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "select_scope_team",
        %{"model_provider" => %{"scope_team_id" => team_id}},
        socket
      ) do
    if socket.assigns.is_admin do
      {:noreply, assign(socket, :current_scope_team_id, team_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("scope_team_search", %{"value" => search}, socket) do
    {:noreply,
     socket
     |> assign(:scope_team_search, search)
     |> assign(:scope_team_open, search != "")}
  end

  def handle_event("scope_member_search", %{"value" => search}, socket) do
    {:noreply,
     socket
     |> assign(:scope_member_search, search)
     |> assign(:scope_member_open, search != "")}
  end

  def handle_event("select_scope_team_item", %{"team_id" => team_id}, socket) do
    if socket.assigns.is_admin do
      team = Enum.find(socket.assigns.teams_for_select || [], &(&1.id == team_id))
      label = if team, do: team.name, else: ""

      {:noreply,
       socket
       |> assign(:current_scope_team_id, team_id)
       |> assign(:scope_team_search, label)
       |> assign(:scope_team_open, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_scope_member_item", %{"member_id" => member_id}, socket) do
    if socket.assigns.is_admin do
      member = Enum.find(socket.assigns.members_for_select || [], &(&1.id == member_id))
      label = if member && member.user, do: member.user.email, else: ""

      {:noreply,
       socket
       |> assign(:current_scope_member_id, member_id)
       |> assign(:scope_member_search, label)
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
           |> load_aliases()}

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
           |> put_flash(:info, "Proveedor eliminado del alias.")
           |> load_aliases()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo eliminar el proveedor.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  def handle_event("reorder_providers", %{"alias_id" => alias_id, "ids" => ids}, socket) do
    if socket.assigns.is_admin do
      valid_ids =
        from(ap in ModelProvider, where: ap.model_alias_id == ^alias_id, select: ap.id)
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

        {:noreply, load_aliases(socket)}
      else
        {:noreply, put_flash(socket, :error, "Orden inválido para este modelo.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No tienes permisos para esta acción.")}
    end
  end

  ## Private helpers — alias save ------------------------------------------

  defp save_alias(socket, :new, alias_params) do
    case Providers.create_model_alias(alias_params) do
      {:ok, _alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Modelo creado.")
         |> assign(:form, nil)
         |> assign(:editing_alias_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_alias))}
    end
  end

  defp save_alias(socket, alias_id, alias_params) when is_binary(alias_id) do
    alias_record = Providers.get_model_alias!(alias_id)

    case Providers.update_model_alias(alias_record, alias_params) do
      {:ok, _alias} ->
        {:noreply,
         socket
         |> put_flash(:info, "Modelo actualizado.")
         |> assign(:form, nil)
         |> assign(:editing_alias_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :model_alias))}
    end
  end

  ## Private helpers — model_provider save ---------------------------------

  defp inject_scope_params(ap_params, assigns) do
    scope = assigns[:current_scope] || "global"

    case scope do
      "member" ->
        ap_params
        |> Map.put("exclusive_to_team_member_id", assigns[:current_scope_member_id])
        |> Map.put("exclusive_to_team_id", nil)

      "team" ->
        ap_params
        |> Map.put("exclusive_to_team_member_id", nil)
        |> Map.put("exclusive_to_team_id", assigns[:current_scope_team_id])

      _ ->
        ap_params
        |> Map.put("exclusive_to_team_member_id", nil)
        |> Map.put("exclusive_to_team_id", nil)
    end
  end

  defp fetch_provider_models(socket, credential_id) do
    credential =
      Enum.find(socket.assigns.credentials_for_select, &(&1.id == credential_id))

    if credential do
      provider = credential.provider
      lv_pid = self()

      Task.start(fn ->
        result = Tokengate.Proxy.OpenAIAdapter.list_models(provider, credential)
        send(lv_pid, {:provider_models_result, result})
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
  def handle_info({:provider_models_result, result}, socket) do
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
         |> put_flash(:error, "No se pudieron cargar los modelos del proveedor.")}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp save_model_provider(socket, :new, ap_params) do
    ap_params = Map.put(ap_params, "model_alias_id", socket.assigns.provider_form_alias_id)

    case Providers.create_model_provider(ap_params) do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor asignado al modelo.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :model_provider))}
    end
  end

  defp save_model_provider(socket, ap_id, ap_params) when is_binary(ap_id) do
    ap = Providers.get_model_provider!(ap_id)

    case Providers.update_model_provider(ap, ap_params) do
      {:ok, _ap} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proveedor actualizado.")
         |> assign(:provider_form, nil)
         |> assign(:editing_ap_id, nil)
         |> load_aliases()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :model_provider))}
    end
  end

  ## Helpers ---------------------------------------------------------------

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

  def format_compact(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 1)}B"

  def format_compact(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_compact(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  def format_compact(n) when is_integer(n), do: Integer.to_string(n)
  def format_compact(n) when is_float(n), do: format_compact(trunc(n))
  def format_compact(_), do: "0"

  def fmt_price(nil), do: "—"
  def fmt_price(%Decimal{} = d), do: "$#{Decimal.round(d, 2) |> Decimal.to_string()}"

  @doc "Scope badge CSS class"
  def scope_badge(%ModelProvider{exclusive_to_team_member_id: id}) when not is_nil(id),
    do: "badge-warning"

  def scope_badge(%ModelProvider{exclusive_to_team_id: id}) when not is_nil(id),
    do: "badge-info"

  def scope_badge(%ModelProvider{}), do: "badge-ghost"
  def scope_badge("member"), do: "badge-warning"
  def scope_badge("team"), do: "badge-info"
  def scope_badge(_), do: "badge-ghost"

  @doc "Scope badge label"
  def scope_label(%ModelProvider{exclusive_to_team_member_id: id}) when not is_nil(id),
    do: "Exclusivo miembro"

  def scope_label(%ModelProvider{exclusive_to_team_id: id}) when not is_nil(id),
    do: "Exclusivo equipo"

  def scope_label(%ModelProvider{}), do: "Global"
  def scope_label("member"), do: "Exclusivo miembro"
  def scope_label("team"), do: "Exclusivo equipo"
  def scope_label(_), do: "Global"

  @doc "Resolve scope to human-readable label with target name"
  def scope_target_label(%ModelProvider{} = mp, assigns) do
    cond do
      mp.exclusive_to_team_member_id ->
        member =
          Enum.find(assigns.members_for_select || [], &(&1.id == mp.exclusive_to_team_member_id))

        if member && member.user, do: member.user.email, else: "Miembro"

      mp.exclusive_to_team_id ->
        team = Enum.find(assigns.teams_for_select || [], &(&1.id == mp.exclusive_to_team_id))
        if team, do: team.name, else: "Equipo"

      true ->
        "Todos"
    end
  end

  def model_providers_for(model_alias) do
    model_alias.model_providers || []
  end

  @doc """
  Group key for scope grouping in the UI: 0 = global, 1 = team-exclusive,
  2 = member-exclusive. Matches the SQL ordering in load_aliases/1.
  """
  def scope_group(%ModelProvider{exclusive_to_team_member_id: id}) when not is_nil(id), do: 2
  def scope_group(%ModelProvider{exclusive_to_team_id: id}) when not is_nil(id), do: 1
  def scope_group(%ModelProvider{}), do: 0

  @doc "Group header label (nil for the global group — no header needed)"
  def scope_group_label(1), do: "Exclusivos por equipo"
  def scope_group_label(2), do: "Exclusivos por usuario"
  def scope_group_label(_), do: nil

  def provider_name(%ModelProvider{credential: %{provider: provider}}) when not is_nil(provider),
    do: provider.name

  def provider_name(_), do: "—"

  def credential_named?(%{name: name}) when is_binary(name) and name != "", do: true
  def credential_named?(_), do: false

  def billing_badge("included"), do: "badge-success"
  def billing_badge(_), do: "badge-ghost"

  def billing_label("included"), do: "Incluida"
  def billing_label(_), do: "Pay per token"

  def enabled_badge(true), do: "badge-success"
  def enabled_badge(_), do: "badge-ghost"

  def enabled_label(true), do: "Activo"
  def enabled_label(false), do: "Inactivo"

  # A model_provider is effectively active only when ITS row is enabled AND
  # its credential exists and is in the "active" state. The credential
  # status is managed in /dashboard/providers and must surface here too —
  # otherwise disabling the credential leaves a misleading "Activo" badge
  # in /dashboard/models even though the router already filters the row out
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
      else: "Credential desactivada — activa en /dashboard/providers"
  end

  def team_options(teams) do
    Enum.map(teams, fn t -> {t.name, t.id} end)
  end

  def member_options(members) do
    Enum.map(members, fn m ->
      label = if m.user, do: m.user.email, else: m.user_id
      {label, m.id}
    end)
  end

  @doc "All teams — the form filter is the search string in the template.
  See members_with_model_access/2 for the rationale."
  def teams_with_model_access(teams, _model_alias_id), do: teams

  @doc "All members — the form filter is the search string in the template.
  The previous access check (TeamModelAlias / TeamMemberExtraAlias) only
  matters for the create flow; in the edit form we want every member to
  appear so the admin can re-pick even if grants have lapsed."
  def members_with_model_access(members, _model_alias_id), do: members

  ## Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.dashboard flash={@flash} current_scope={@current_user} impersonator={@impersonator}>
      <div class="space-y-6">
        <.header>
          Modelos
          <:subtitle>Configura modelos y sus proveedores de routing</:subtitle>
          <:actions :if={@is_admin}>
            <button
              phx-click="new_alias"
              class="btn btn-primary btn-sm"
              id="new-model-btn"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Nuevo Modelo
            </button>
          </:actions>
        </.header>

        <%!-- Alias list --%>
        <%!-- The empty state must live OUTSIDE the stream container:
             phx-update="stream" only manages children keyed by stream ids,
             so a plain conditional div inside it never reaches the client. --%>
        <div
          :if={@aliases_empty?}
          id="aliases-empty"
          class="text-center py-12 text-base-content/40"
        >
          <.icon name="hero-cpu-chip" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>No hay modelos configurados.</p>
        </div>

        <div id="aliases" phx-update="stream" class="space-y-3">
          <div :for={{id, model_alias} <- @streams.aliases} id={id}>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-5">
                <div class="flex items-start justify-between gap-4">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 flex-wrap">
                      <h3 class="font-semibold text-base-content truncate">
                        {model_alias.name}
                      </h3>
                      <span
                        class="text-xs text-base-content/40"
                        title={"#{model_alias.context_window} tokens"}
                      >
                        · {format_compact(model_alias.context_window)} ctx
                      </span>
                      <span
                        :if={model_alias.model_type != "llm"}
                        class="badge badge-sm badge-outline badge-info"
                      >
                        {model_alias.model_type}
                      </span>
                    </div>
                    <p class="text-sm text-base-content/60 mt-1">{model_alias.display_name}</p>
                  </div>

                  <div class="flex gap-2 shrink-0">
                    <%= if @is_admin do %>
                      <button
                        phx-click="edit_guard_rails"
                        phx-value-id={model_alias.id}
                        class="btn btn-sm btn-ghost"
                        id={"guard-rails-#{model_alias.id}"}
                      >
                        <.icon name="hero-shield-check" class="w-4 h-4" /> Guard Rails
                      </button>
                      <button
                        phx-click="edit_alias"
                        phx-value-id={model_alias.id}
                        class="btn btn-sm btn-ghost"
                        id={"edit-alias-#{model_alias.id}"}
                      >
                        <.icon name="hero-pencil-square" class="w-4 h-4" /> Editar
                      </button>
                      <button
                        phx-click="delete_alias"
                        phx-value-id={model_alias.id}
                        data-confirm="¿Eliminar este modelo? Esta acción no se puede deshacer."
                        class="btn btn-sm btn-ghost text-error"
                        id={"delete-alias-#{model_alias.id}"}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>

                <%!-- Alias providers list (inline) --%>
                <div class="mt-4 pt-4 border-t border-base-200">
                  <div class="flex items-center justify-between mb-2">
                    <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                      Proveedores asignados
                    </h4>
                    <%= if @is_admin do %>
                      <button
                        phx-click="new_model_provider"
                        phx-value-alias_id={model_alias.id}
                        class="btn btn-xs btn-primary"
                        id={"new-ap-#{model_alias.id}"}
                      >
                        <.icon name="hero-plus" class="w-3 h-3" /> Asignar Proveedor
                      </button>
                    <% end %>
                  </div>

                  <div
                    :if={model_providers_for(model_alias) == []}
                    class="text-sm text-base-content/40 py-2"
                  >
                    No hay proveedores asignados.
                  </div>

                  <div :if={model_providers_for(model_alias) != []} class="overflow-x-auto">
                    <table class="table table-sm">
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
                        id={"ap-sortable-#{model_alias.id}"}
                        phx-hook="SortableProviders"
                        data-alias-id={model_alias.id}
                      >
                        <% providers = model_providers_for(model_alias) %>
                        <% groups = Enum.map(providers, &scope_group/1) %>
                        <% prev_groups = [nil | Enum.drop(groups, -1)] %>
                        <%= for {ap, prev_group} <- Enum.zip(providers, prev_groups) do %>
                          <% current_group = scope_group(ap) %>
                          <%!-- Group separator: a divider line + subtitle row when
                               the scope group changes (global → team → member). --%>
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
                            id={"alias-provider-#{ap.id}"}
                            data-id={ap.id}
                            draggable={to_string(@is_admin)}
                            class={[@is_admin && "cursor-grab active:cursor-grabbing"]}
                          >
                            <td :if={@is_admin} class="w-8 text-base-content/30">
                              <.icon name="hero-bars-3" class="w-4 h-4" />
                            </td>
                            <td class="font-medium">
                              {provider_name(ap)}
                              <span
                                :if={ap.credential && credential_named?(ap.credential)}
                                class="badge badge-xs badge-outline font-normal ml-1"
                                title={ap.credential.name}
                              >
                                <.icon name="hero-key" class="w-3 h-3" />
                                {ap.credential.name}
                              </span>
                              <span
                                :if={ap.credential}
                                class="text-xs text-base-content/40 ml-1"
                              >
                                {mask_key(ap.credential.api_key_encrypted)}
                              </span>
                            </td>
                            <td><code class="text-sm">{ap.provider_model}</code></td>
                            <td>
                              <span class={["badge", "badge-sm", billing_badge(ap.billing_mode)]}>
                                {billing_label(ap.billing_mode)}
                              </span>
                            </td>
                            <td>
                              <span class="badge badge-xs badge-ghost">{ap.priority || "—"}</span>
                            </td>
                            <td>
                              <span class={["badge", "badge-sm", scope_badge(ap)]}>
                                {scope_label(ap)}
                              </span>
                              <%= if ap.exclusive_to_team_member_id || ap.exclusive_to_team_id do %>
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
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_alias_id == :new, do: "Nuevo Modelo", else: "Editar Modelo"}
              </h2>

              <.form for={@form} id="alias-form" phx-submit="save_alias">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nombre (identificador)"
                  required
                  hint="Nombre interno del modelo, ej. gpt-4o. Debe ser único."
                />
                <.input
                  field={@form[:display_name]}
                  type="text"
                  label="Nombre para mostrar"
                  required
                  hint="Nombre visible para los usuarios en /v1/models."
                />
                <.input
                  field={@form[:description]}
                  type="textarea"
                  label="Descripción"
                  hint="Descripción corta del modelo para el catálogo del dashboard."
                />
                <.input
                  field={@form[:context_window]}
                  type="number"
                  label="Ventana de contexto (tokens)"
                  required
                  hint="Tamaño máximo de contexto del modelo en tokens."
                />

                <.input
                  field={@form[:model_type]}
                  type="select"
                  label="Tipo de modelo"
                  options={[{"LLM (chat)", "llm"}, {"Embedding", "embedding"}, {"Rerank", "rerank"}]}
                  hint="Define qué endpoint lo sirve: /v1/chat/completions, /v1/embeddings o /v1/rerank."
                />

                <div :if={@form[:model_type].value in [nil, "llm", ""]}>
                  <div class="divider my-3 text-xs text-base-content/50">Optimización</div>

                  <.input
                    field={@form[:prompt_cache_enabled]}
                    type="checkbox"
                    label="Prompt caching (prefix estable)"
                    hint="Reordena system prompts al frente y dedupe para maximizar cache hits del proveedor."
                  />

                  <.input
                    field={@form[:lazy_cleanup_enabled]}
                    type="checkbox"
                    label="Limpieza perezosa sin LLM"
                    hint="Dedupe de tool outputs y recorte de bloques largos. 100% determinista, sin inferencia."
                  />
                </div>

                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    Cancelar
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-alias-btn">
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
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_ap_id == :new, do: "Asignar Proveedor", else: "Editar Proveedor"}
              </h2>

              <.form
                for={@provider_form}
                id="alias-provider-form"
                phx-submit="save_model_provider"
                phx-change="provider_form_changed"
              >
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
                    Cargando modelos del proveedor…
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

                <%!-- Scope selector --%>
                <div class="mt-4 mb-2">
                  <label class="text-sm font-medium text-base-content">Alcance (Scope)</label>
                  <p class="text-xs text-base-content/50 mb-2">
                    Global = todos los miembros con acceso. Exclusivo = solo el miembro o equipo seleccionado.
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
                      phx-value-scope="team"
                      class={["btn btn-sm", @current_scope == "team" && "btn-info"]}
                    >
                      <.icon name="hero-users" class="w-4 h-4" /> Equipo
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
                  <div class="relative">
                    <label class="text-sm font-medium text-base-content">Usuario exclusivo</label>
                    <p class="text-xs text-base-content/50 mb-1">
                      Solo este usuario podrá usar esta API key para este modelo.
                    </p>
                    <input
                      type="text"
                      name="model_provider[scope_member_id_display]"
                      value={@scope_member_search}
                      placeholder="Escribe para buscar usuario…"
                      phx-keyup="scope_member_search"
                      phx-debounce="200"
                      class="input input-sm w-full"
                      autocomplete="off"
                    />
                    <% members_filtered =
                      members_with_model_access(@members_for_select, @provider_form_alias_id)
                      |> Enum.filter(fn m ->
                        search = String.downcase(@scope_member_search || "")
                        email = if m.user, do: String.downcase(m.user.email), else: ""
                        name = if m.user && m.user.name, do: String.downcase(m.user.name), else: ""

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
                  </div>
                <% end %>

                <%= if @current_scope == "team" do %>
                  <div class="relative">
                    <label class="text-sm font-medium text-base-content">Equipo exclusivo</label>
                    <p class="text-xs text-base-content/50 mb-1">
                      Solo los miembros de este equipo podrán usar esta API key para este modelo.
                    </p>
                    <input
                      type="text"
                      name="model_provider[scope_team_id_display]"
                      value={@scope_team_search}
                      placeholder="Escribe para buscar equipo…"
                      phx-keyup="scope_team_search"
                      phx-debounce="200"
                      class="input input-sm w-full"
                      autocomplete="off"
                    />
                    <% teams_filtered =
                      teams_with_model_access(@teams_for_select, @provider_form_alias_id)
                      |> Enum.filter(fn t ->
                        search = String.downcase(@scope_team_search || "")
                        name = String.downcase(t.name || "")
                        search == "" or String.contains?(name, search)
                      end) %>
                    <%= if @scope_team_open and teams_filtered != [] do %>
                      <div class="absolute z-50 left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-40 overflow-y-auto">
                        <button
                          :for={t <- Enum.take(teams_filtered, 10)}
                          type="button"
                          phx-click="select_scope_team_item"
                          phx-value-team_id={t.id}
                          class={[
                            "block w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors border-b border-base-300/50 last:border-0",
                            t.id == @current_scope_team_id && "bg-primary/10 font-semibold"
                          ]}
                        >
                          <span class="text-sm font-medium">{t.name}</span>
                          <span
                            :if={t.id == @current_scope_team_id}
                            class="text-xs text-primary ml-2"
                          >
                            (actual)
                          </span>
                        </button>
                      </div>
                    <% end %>
                    <input
                      type="hidden"
                      name="model_provider[scope_team_id]"
                      value={@current_scope_team_id}
                    />
                  </div>
                <% end %>

                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@provider_form[:priority]}
                    type="number"
                    label="Prioridad"
                    hint="Menor = se intenta primero."
                  />
                  <.input
                    field={@provider_form[:billing_mode]}
                    type="select"
                    label="Facturación"
                    options={[
                      {"Pay per token", "pay_per_token"},
                      {"Incluida (suscripción)", "included"}
                    ]}
                    hint="Pay per token: cobra por uso. Incluida: suscripción/RPM = $0."
                  />
                </div>

                <.input
                  field={@provider_form[:sticky_ttl_seconds]}
                  type="number"
                  label="TTL sticky (segundos)"
                  hint="Cuánto se queda pegada la misma credencial para esta API key. Vacío = 900 s (15 min, default). Mínimo 1 s, máximo 86 400 s (24 h). Se guarda en milisegundos."
                />

                <.input
                  field={@provider_form[:enabled]}
                  type="checkbox"
                  label="Habilitado"
                  hint="Si está apagado, este provider no recibe tráfico del modelo."
                />

                <div class="flex gap-2 mt-4 justify-end">
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
