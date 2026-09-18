defmodule TokengateWeb.ProvidersLive do
  @moduledoc """
  Admin CRUD for providers + per-provider credential management.

  The provider owns the operational limits (`max_rpm`, `max_concurrent`,
  `max_concurrent_per_user`, `receive_timeout_ms`) and every credential of
  that provider inherits them — a credential is just an alias + API key.
  Those fields are editable for builtins too; their catalog identity isn't.

  Pricing is managed per ModelProvider (model × credential) in the
  Models section, not here.

  Deleting a provider that is referenced by model_providers is blocked
  with a friendly Spanish flash message.
  """

  use TokengateWeb, :live_view

  require Logger

  import Ecto.Query, only: [from: 2]
  alias Tokengate.Providers

  alias Tokengate.Providers.{
    Catalog,
    Provider,
    Credential,
    ModelProvider,
    ProviderLimits,
    ProviderPaths
  }

  alias Tokengate.Repo

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tokengate.PubSub, Tokengate.Logs.Inflight.topic())
    end

    socket =
      socket
      |> assign(:page_title, gettext("Providers") <> " · Tokengate")
      |> assign(:form, nil)
      |> assign(:editing_provider_id, nil)
      |> assign(:credential_form, nil)
      |> assign(:editing_credential_id, nil)
      |> assign(:catalog_modal_open, false)
      |> assign(:catalog_query, "")
      |> assign(:editing_provider_builtin?, false)
      |> assign(:paths_form, nil)
      |> assign(:paths_provider_id, nil)
      |> assign(:paths_provider_name, nil)
      |> assign(:path_service_rows, [])
      |> assign(:is_admin, user && user.global_role == "admin")
      |> assign(:credential_inflight, %{})
      |> require_admin_hook()
      |> load_providers()

    {:ok, socket}
  end

  # Defense-in-depth: the router already gates this LiveView behind
  # live_session :admin, but a malicious client could fire events directly
  # over the WebSocket. Halt every event for non-admins.
  defp require_admin_hook(socket) do
    attach_hook(socket, :require_admin, :handle_event, fn _event, _params, socket ->
      if socket.assigns[:is_admin] do
        {:cont, socket}
      else
        {:halt, put_flash(socket, :error, "No autorizado.")}
      end
    end)
  end

  ## Data loading ---------------------------------------------------------

  # El motivo de "no soportado" es un msgid de datos que sale del contexto
  # (`Catalog`): `nil` cuando el proveedor sí se puede usar, así que no puede
  # pasar directo a `translate/1`.
  defp translate_reason(nil), do: nil
  defp translate_reason(reason), do: TokengateWeb.Gettext.translate(reason)

  defp load_providers(socket) do
    providers =
      from(p in Provider,
        left_join: c in assoc(p, :credentials),
        preload: [credentials: c],
        # Only providers in use: those with at least one credential.
        # Seeded builtins without API keys stay invisible until a
        # credential attaches to them.
        where: not is_nil(c.id) or p.source == "custom",
        # Builtin primero, custom al final (`false` ordena antes que `true` en
        # Postgres) y, dentro de cada grupo, por nombre. La lista ya no se
        # filtra por origen: se muestra entera.
        order_by: [asc: p.source == "custom", asc: p.name]
      )
      |> Repo.all()

    # Count model_providers per provider for display
    credential_ids =
      providers
      |> Enum.flat_map(& &1.credentials)
      |> Enum.map(& &1.id)

    model_counts =
      if credential_ids == [] do
        %{}
      else
        from(mp in ModelProvider,
          where: mp.credential_id in ^credential_ids,
          group_by: mp.credential_id,
          select: {mp.credential_id, count(mp.id)}
        )
        |> Repo.all()
        |> Enum.into(%{})
      end

    # Map credential counts to provider counts
    provider_model_counts =
      Enum.reduce(providers, %{}, fn provider, acc ->
        count =
          provider.credentials
          |> Enum.map(&Map.get(model_counts, &1.id, 0))
          |> Enum.sum()

        Map.put(acc, provider.id, count)
      end)

    # Fetch circuit breaker status for every credential in one Registry sweep
    # (instead of one lookup + GenServer call per credential). Unknown
    # credentials simply don't appear — the template must default to :closed.
    alias Tokengate.Routing.CircuitBreakerManager

    breaker_statuses =
      CircuitBreakerManager.status_all()
      |> then(fn all ->
        providers
        |> Enum.flat_map(& &1.credentials)
        |> Map.new(fn cred -> {cred.id, Map.get(all, cred.id, :closed)} end)
      end)

    socket
    |> assign(:providers, providers)
    |> assign(:providers_empty?, providers == [])
    |> assign(:provider_model_counts, provider_model_counts)
    |> assign(:breaker_statuses, breaker_statuses)
    |> load_catalog()
    |> assign_inflight()
  end

  # Catalog rows for the add-provider modal: the models.dev mirror decorated
  # with the live state (already activated = has a credential). Rows the
  # gateway cannot serve (no base URL, templated URL, no OpenAI-compatible
  # dialect) never enter the picker — they could not be activated anyway.
  # Capabilities stay OUT of the picker and of the cards: they are code
  # configuration, not something the operator sets here.
  defp load_catalog(socket) do
    activated_keys =
      from(p in Provider,
        join: c in assoc(p, :credentials),
        where: not is_nil(p.key),
        distinct: true,
        select: p.key
      )
      |> Repo.all()
      |> MapSet.new()

    entries =
      Providers.list_catalog_providers()
      |> Enum.filter(&Catalog.supported?/1)
      |> Enum.map(fn row ->
        %{
          key: row.key,
          name: row.name,
          base_url: Catalog.base_url(row),
          doc_url: row.doc_url,
          logo_url: row.logo_url,
          status: row.status,
          reason: translate_reason(Catalog.unsupported_reason(row)),
          activated?: MapSet.member?(activated_keys, row.key)
        }
      end)

    socket
    |> assign(:catalog_entries, entries)
    |> assign(:catalog_total, length(entries))
    |> assign(:catalog_results, entries)
  end

  # Live in-flight counts per credential (open upstream connections), recomputed
  # on every `:inflight_started`/`:inflight_done` PubSub event without a DB hit.
  defp assign_inflight(socket) do
    credential_counts =
      Tokengate.Logs.Inflight.count_by_credential()
      |> Map.new(fn %{credential_id: id, count: n} -> {id, n} end)

    assign(socket, :credential_inflight, credential_counts)
  end

  ## Live in-flight refresh -------------------------------------------------

  @impl true
  def handle_info({:inflight_started, _entry}, socket) do
    {:noreply, assign_inflight(socket)}
  end

  def handle_info({:inflight_done, _id}, socket) do
    {:noreply, assign_inflight(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Events — provider CRUD ------------------------------------------------

  @impl true
  # Adds a custom provider: no catalog entry exists for it, so the form asks
  # for the base URL alone. Dialect, paths and capabilities are NOT asked for
  # — they are code (dialect default + Catalog customization).
  def handle_event("new_custom_provider", _params, socket) do
    changeset =
      Providers.change_provider(%Provider{
        source: "custom",
        dialect: "openai"
      })

    {:noreply,
     socket
     |> assign(:catalog_modal_open, false)
     |> assign(:form, to_form(changeset, as: :provider))
     |> assign(:editing_provider_id, :new)
     |> assign(:editing_provider_builtin?, false)}
  end

  # Opens the models.dev catalog modal — the "Agregar proveedor" entry point
  # (the old dropdown could not scale to a few hundred providers).
  def handle_event("open_catalog_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:catalog_modal_open, true)
     |> filter_catalog("")}
  end

  def handle_event("close_catalog_modal", _params, socket) do
    {:noreply, assign(socket, :catalog_modal_open, false)}
  end

  # Search over name and models.dev id. In memory: the mirror is a few hundred
  # rows, so every keystroke is instant and costs no query.
  def handle_event("search_catalog", params, socket) do
    {:noreply, filter_catalog(socket, params["query"] || "")}
  end

  # Attaching an API key IS what activates a catalog provider: the credential
  # modal opens with the provider already assigned. Builtin rows are
  # materialized at boot, so the row exists before its first key.
  def handle_event("activate_catalog_provider", %{"key" => key}, socket) do
    entry = Enum.find(socket.assigns.catalog_entries, &(&1.key == key))

    cond do
      is_nil(entry) ->
        {:noreply, put_flash(socket, :error, gettext("Unknown provider."))}

      true ->
        case Repo.get_by(Provider, key: key) do
          nil ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("%{name} is not materialized yet. Try again.", name: entry.name)
             )}

          provider ->
            changeset =
              Providers.change_credential(%Credential{
                provider_id: provider.id,
                status: "active"
              })

            {:noreply,
             socket
             |> assign(:catalog_modal_open, false)
             |> assign(:credential_form, to_form(changeset, as: :credential))
             |> assign(:editing_credential_id, nil)}
        end
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, nil)
     |> assign(:editing_provider_id, nil)}
  end

  ## Events — capability paths ----------------------------------------------

  # Opens the Capacidades modal: one path input per service, pre-filled with
  # the provider's own overrides — an empty input means "inherit", which is
  # the normal state.
  def handle_event("edit_paths", %{"id" => provider_id}, socket) do
    provider = Providers.get_provider!(provider_id)
    {:noreply, open_paths_modal(socket, provider, ProviderPaths.overrides(provider))}
  end

  def handle_event("cancel_paths", _params, socket) do
    {:noreply, close_paths_modal(socket)}
  end

  # An empty input is dropped by `normalize/1`, so "leave it blank" and "clear
  # an override" are the same gesture and the column keeps one shape.
  def handle_event("save_paths", %{"paths" => params}, socket) do
    provider = Providers.get_provider!(socket.assigns.paths_provider_id)
    submitted = Map.delete(params, "provider_id")

    case ProviderPaths.normalize(submitted) do
      {:ok, overrides} ->
        case Providers.update_provider(provider, %{path_overrides: overrides}) do
          {:ok, _provider} ->
            audit(socket, "provider.paths_update", "provider", provider.id, %{
              "name" => provider.name,
              "path_overrides" => overrides
            })

            {:noreply,
             socket
             |> put_flash(:info, paths_flash(overrides))
             |> close_paths_modal()
             |> load_providers()}

          {:error, changeset} ->
            {:noreply,
             reject_paths(socket, provider, submitted, changeset_error_message(changeset))}
        end

      {:error, message} ->
        {:noreply, reject_paths(socket, provider, submitted, message)}
    end
  end

  # Editing a builtin is allowed on purpose: its operational limits belong to
  # the operator while its identity (name, base_url) stays catalog-owned — the
  # form renders those read-only and the changeset discards any change to them
  # anyway.
  def handle_event("edit_provider", %{"id" => provider_id}, socket) do
    provider = Providers.get_provider!(provider_id)
    changeset = Providers.change_provider(provider)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :provider))
     |> assign(:editing_provider_id, provider.id)
     |> assign(:editing_provider_builtin?, provider.source == "builtin")}
  end

  def handle_event("save_provider", %{"provider" => provider_params}, socket) do
    save_provider(socket, socket.assigns.editing_provider_id, provider_params)
  end

  def handle_event("delete_provider", %{"id" => provider_id}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.id == provider_id))

    cond do
      is_nil(provider) ->
        {:noreply, socket}

      provider.source == "builtin" ->
        # Builtins come from the compile-time catalog: deleting them would
        # lose their credentials, and the boot sync would re-insert the row
        # anyway. Disable instead.
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Catalog providers cannot be deleted — deactivate it to take it out of the routing (it is recreated on boot)."
           )
         )}

      true ->
        delete_provider(socket, provider)
    end
  end

  def handle_event("toggle_provider", %{"id" => provider_id}, socket) do
    provider = Providers.get_provider!(provider_id)
    new_status = if provider.status == "active", do: "disabled", else: "active"

    case Providers.update_provider(provider, %{status: new_status}) do
      {:ok, _} ->
        audit(socket, "provider.toggle_status", "provider", provider.id, %{
          "name" => provider.name,
          "status" => new_status
        })

        {:noreply,
         socket
         |> put_flash(
           :info,
           if(new_status == "active",
             do: gettext("Provider activated."),
             else: gettext("Provider deactivated.")
           )
         )
         |> load_providers()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the provider."))}
    end
  end

  ## Events — credential management ----------------------------------------

  def handle_event("new_credential", %{"provider_id" => provider_id}, socket) do
    changeset =
      Providers.change_credential(%Credential{provider_id: provider_id, status: "active"})

    {:noreply,
     socket
     |> assign(:credential_form, to_form(changeset, as: :credential))
     |> assign(:editing_credential_id, nil)}
  end

  def handle_event("edit_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    changeset =
      cred
      |> Providers.change_credential()

    {:noreply,
     socket
     |> assign(:credential_form, to_form(changeset, as: :credential))
     |> assign(:editing_credential_id, cred.id)}
  end

  def handle_event("cancel_credential", _params, socket) do
    {:noreply, socket |> assign(:credential_form, nil) |> assign(:editing_credential_id, nil)}
  end

  def handle_event("save_credential", %{"credential" => cred_params}, socket) do
    editing_id = socket.assigns[:editing_credential_id]

    if editing_id do
      cred = Providers.get_credential!(editing_id)

      # Si el api_key viene vacío, evitamos sobrescribir — lo removemos
      cred_params =
        if cred_params["api_key_encrypted"] in [nil, ""] do
          Map.drop(cred_params, ["api_key_encrypted"])
        else
          cred_params
        end

      case Providers.update_credential(cred, cred_params) do
        {:ok, _cred} ->
          audit(socket, "credential.update", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name,
            "key_rotated" => Map.has_key?(cred_params, "api_key_encrypted")
          })

          {:noreply,
           socket
           |> put_flash(:info, "Credencial actualizada.")
           |> assign(:credential_form, nil)
           |> assign(:editing_credential_id, nil)
           |> load_providers()}

        {:error, changeset} ->
          {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
      end
    else
      case Providers.create_credential(cred_params) do
        {:ok, cred} ->
          audit(socket, "credential.create", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name
          })

          {:noreply,
           socket
           |> put_flash(:info, "Credencial creada.")
           |> assign(:credential_form, nil)
           |> assign(:editing_credential_id, nil)
           |> load_providers()}

        {:error, changeset} ->
          {:noreply, assign(socket, :credential_form, to_form(changeset, as: :credential))}
      end
    end
  end

  def handle_event("toggle_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    # Credentials in "error" state cannot be toggled — they must be reactivated.
    if cred.status == "error" do
      {:noreply,
       put_flash(socket, :error, gettext("This credential is in error. Use Reactivate."))}
    else
      new_status = if cred.status == "active", do: "disabled", else: "active"

      case Providers.update_credential(cred, %{status: new_status}) do
        {:ok, _} ->
          audit(socket, "credential.toggle_status", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name,
            "status" => new_status
          })

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Credencial #{if(new_status == "active", do: "activada", else: "desactivada")}."
           )
           |> load_providers()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the credential."))}
      end
    end
  end

  def handle_event("reactivate_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    if cred.status == "error" do
      case Providers.reactivate_credential(cred) do
        {:ok, _} ->
          audit(socket, "credential.reactivate", "credential", cred.id, %{
            "provider_id" => cred.provider_id,
            "name" => cred.name
          })

          {:noreply,
           socket
           |> put_flash(:info, "Credencial reactivada.")
           |> load_providers()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not reactivate the credential."))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only credentials in error can be reactivated."))}
    end
  end

  def handle_event("reset_breaker", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    Tokengate.Routing.CircuitBreakerManager.reset(cred.id)

    audit(socket, "credential.breaker_reset", "credential", cred.id, %{
      "provider_id" => cred.provider_id,
      "name" => cred.name
    })

    {:noreply,
     socket
     |> put_flash(:info, "Circuit breaker reseteado.")
     |> load_providers()}
  end

  def handle_event("delete_credential", %{"id" => cred_id}, socket) do
    cred = Providers.get_credential!(cred_id)

    case Providers.delete_credential(cred) do
      {:ok, _} ->
        audit(socket, "credential.delete", "credential", cred.id, %{
          "provider_id" => cred.provider_id,
          "name" => cred.name
        })

        {:noreply,
         socket
         |> put_flash(:info, "Credencial eliminada.")
         |> load_providers()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the credential."))}
    end
  end

  ## Private helpers — provider save --------------------------------------

  defp delete_provider(socket, provider) do
    referenced? =
      Repo.exists?(
        from(mp in ModelProvider,
          join: c in assoc(mp, :credential),
          where: c.provider_id == ^provider.id
        )
      )

    if referenced? do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Cannot delete: the provider is in use by one or more models.")
       )}
    else
      # Slow deletes surface as exceptions, not {:error, _}: a client-side
      # timeout raises DBConnection.ConnectionError; a server-side
      # statement_timeout or deadlock raises Postgrex.Error (query_canceled /
      # 40P01). Without this the LiveView crashes and the user sees nothing.
      try do
        case Providers.delete_provider(provider) do
          {:ok, _} ->
            audit(socket, "provider.delete", "provider", provider.id, %{"name" => provider.name})

            {:noreply,
             socket
             |> put_flash(:info, gettext("Provider deleted."))
             |> load_providers()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete the provider."))}
        end
      rescue
        e in [DBConnection.ConnectionError, Postgrex.Error] ->
          Logger.warning("delete_provider/1 DB error for #{provider.id}: #{Exception.message(e)}")

          {:noreply,
           put_flash(
             socket,
             :error,
             gettext(
               "The delete failed in the database (timeout or lock). Try again; if it persists, contact an administrator."
             )
           )}
      end
    end
  end

  # Capabilities for a custom come straight from the form (there is no catalog
  # entry to derive them from); builtins get them from `Catalog`.
  defp save_provider(socket, :new, provider_params) do
    case Providers.create_provider(provider_params) do
      {:ok, provider} ->
        audit(socket, "provider.create", "provider", provider.id, %{
          "name" => provider.name,
          "key" => provider.key
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Provider created."))
         |> assign(:form, nil)
         |> assign(:editing_provider_id, nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :provider))}
    end
  end

  defp save_provider(socket, provider_id, provider_params) when is_binary(provider_id) do
    provider = Providers.get_provider!(provider_id)

    case Providers.update_provider(provider, provider_params) do
      {:ok, updated} ->
        audit(socket, "provider.update", "provider", updated.id, %{
          "name" => updated.name,
          "changes" =>
            Map.take(provider_params, [
              "name",
              "status",
              "base_url",
              "billing_type",
              "dialect",
              "capabilities",
              "max_rpm",
              "max_concurrent",
              "max_concurrent_per_user",
              "receive_timeout_ms"
            ])
        })

        {:noreply,
         socket
         |> put_flash(:info, gettext("Provider updated."))
         |> assign(:form, nil)
         |> assign(:editing_provider_id, nil)
         |> load_providers()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :provider))}
    end
  end

  # Catalog search: filters the in-memory mirror by name or models.dev id.
  defp filter_catalog(socket, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    results =
      if needle == "" do
        socket.assigns.catalog_entries
      else
        Enum.filter(socket.assigns.catalog_entries, fn entry ->
          String.contains?(String.downcase(entry.name), needle) or
            String.contains?(String.downcase(entry.key), needle)
        end)
      end

    socket
    |> assign(:catalog_query, query)
    |> assign(:catalog_results, results)
  end

  ## Private helpers — capability paths ------------------------------------

  # Modal state for one provider: the form (pre-filled with what the operator
  # last typed, so a rejected save loses nothing) plus the rows the template
  # renders — label, the path an empty input inherits as the placeholder
  # (the provider's hardcoded catalog path, else the adapter default), and a
  # hint saying which tier wins today.
  defp open_paths_modal(socket, provider, values) do
    params =
      Enum.reduce(ProviderPaths.services(), %{"provider_id" => provider.id}, fn service, acc ->
        Map.put(acc, service.key, path_value(values, service.key))
      end)

    socket
    |> assign(:paths_provider_id, provider.id)
    |> assign(:paths_provider_name, provider.name)
    |> assign(:path_service_rows, path_service_rows(provider))
    |> assign(:paths_form, to_form(params, as: :paths))
  end

  defp close_paths_modal(socket) do
    socket
    |> assign(:paths_form, nil)
    |> assign(:paths_provider_id, nil)
    |> assign(:paths_provider_name, nil)
    |> assign(:path_service_rows, [])
  end

  # Keeps the modal open with what was typed and says why nothing was saved.
  defp reject_paths(socket, provider, submitted, message) do
    socket
    |> put_flash(:error, message)
    |> open_paths_modal(provider, submitted)
  end

  defp path_value(values, key) do
    case Map.get(values, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp path_service_rows(provider) do
    Enum.map(ProviderPaths.describe_all(provider), fn description ->
      %{
        key: description.key,
        label: description.label,
        placeholder: description.catalog || description.default,
        hint: path_hint(description)
      }
    end)
  end

  # Says where the path in effect comes from, so an override that is not the
  # one being edited is still visible from inside the modal.
  defp path_hint(%{source: :provider, catalog: catalog, default: default}),
    do: gettext("Own override · default: %{default}", default: catalog || default)

  defp path_hint(%{source: :catalog, default: default}),
    do: gettext("Catalog path · default: %{default}", default: default)

  defp path_hint(_description), do: gettext("Adapter default")

  defp paths_flash(overrides) do
    case map_size(overrides) do
      0 -> gettext("Paths reset: every capability falls back to its default.")
      n -> "Paths actualizados (#{n} #{if n == 1, do: "override", else: "overrides"})."
    end
  end

  defp changeset_error_message(changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.map_join(" · ", fn {field, messages} ->
        "#{field}: #{Enum.join(messages, ", ")}"
      end)

    gettext("Could not save the paths — %{details}", details: details)
  end

  ## Helpers ---------------------------------------------------------------

  @doc "Credentials for a provider (from preloaded map)."
  def credentials_for(%{credentials: creds}), do: creds
  def credentials_for(_), do: []

  @doc "How many capabilities this provider overrides — the badge on its button."
  def path_override_count(provider), do: map_size(ProviderPaths.overrides(provider))

  @doc "Model count for a provider (from the counts map)."
  def model_count(provider_id, counts), do: Map.get(counts, provider_id, 0)

  @doc """
  Timeout label for a provider: the effective value, flagging when it is the
  global default rather than a value set on the provider.
  """
  def timeout_label(provider) do
    ms = ProviderLimits.receive_timeout_ms(provider)

    if is_nil(provider.receive_timeout_ms), do: "#{ms} ms (global)", else: "#{ms} ms"
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

  @doc "Format a decimal for display."
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc "Format a datetime for display."
  def fmt_dt(nil, _timezone), do: "—"

  def fmt_dt(%DateTime{} = dt, timezone) do
    TokengateWeb.TimezoneHelper.format_datetime_iso(dt, timezone)
  end

  @doc "Human-readable label for circuit breaker state."
  def breaker_label(:closed), do: gettext("Closed")
  def breaker_label(:open), do: gettext("Open")
  def breaker_label(:half_open), do: "Half-Open"
  def breaker_label(_), do: "—"

  @doc """
  Row highlight class for credentials that need attention: error status,
  open/half-open circuit breaker (red), or manually disabled (muted).
  """
  def credential_row_class(%Credential{status: "error"}, _breaker),
    do: "bg-error/10 hover:bg-error/20"

  def credential_row_class(_cred, breaker) when breaker in [:open, :half_open],
    do: "bg-error/10 hover:bg-error/20"

  def credential_row_class(%Credential{status: "disabled"}, _breaker),
    do: "bg-warning/10 hover:bg-warning/20"

  def credential_row_class(_cred, _breaker), do: nil

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
          {gettext("Providers")}
          <:subtitle>{gettext("LLM providers and credentials")}</:subtitle>
          <:actions>
            <.button phx-click="open_catalog_modal" id="add-provider-btn">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add provider")}
            </.button>
          </:actions>
        </.header>

        <%!-- Add-provider modal: searchable list of what the gateway can
             serve. Rows without base URL, with a templated URL or without an
             OpenAI-compatible dialect are filtered out; rows already
             carrying a credential render as activated (more keys come from
             their own card). --%>
        <div
          :if={@catalog_modal_open}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id="catalog-modal"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="close_catalog_modal" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-3xl">
            <div class="card-body p-5 max-h-[85vh] flex flex-col">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="text-lg font-semibold">{gettext("Add provider")}</h2>
                  <p class="text-xs text-base-content/60 mt-1">
                    {gettext(
                      "models.dev catalog (%{count} providers). Picking one opens its credential.",
                      count: @catalog_total
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="close_catalog_modal"
                  class="btn btn-ghost btn-sm btn-circle"
                  id="close-catalog-modal"
                  aria-label={gettext("Close")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>

              <form
                id="catalog-search-form"
                phx-change="search_catalog"
                phx-submit="search_catalog"
                class="mt-2"
              >
                <input
                  type="text"
                  name="query"
                  id="catalog-search"
                  value={@catalog_query}
                  placeholder={gettext("Search provider or id (openrouter, fireworks, qwen…)")}
                  class="input input-sm w-full"
                  autocomplete="off"
                />
              </form>

              <button
                type="button"
                phx-click="new_custom_provider"
                class="text-left px-3 py-2 mt-2 rounded-lg border border-dashed border-base-300 hover:bg-base-200 flex justify-between items-center"
                id="new-custom-provider-btn"
              >
                <span class="flex items-center gap-2">
                  <.icon name="hero-wrench-screwdriver" class="w-4 h-4" />
                  <span class="font-medium">{gettext("Custom provider")}</span>
                </span>
                <span class="text-xs opacity-50">OPENAI-COMPATIBLE</span>
              </button>

              <div class="divider my-1"></div>

              <div
                class="overflow-y-auto flex-1 min-h-0 -mx-1 px-1"
                id="catalog-results"
                phx-update="replace"
              >
                <div
                  :for={entry <- @catalog_results}
                  id={"catalog-row-#{entry.key}"}
                  class="rounded-lg hover:bg-base-200"
                >
                  <div class="flex items-center gap-3 p-2">
                    <div
                      tabindex="0"
                      role="button"
                      id={"activate-catalog-#{entry.key}"}
                      phx-click={
                        if(not entry.activated?,
                          do: "activate_catalog_provider",
                          else: nil
                        )
                      }
                      phx-value-key={entry.key}
                      class={[
                        "flex items-center gap-3 flex-1 min-w-0 rounded-lg text-left",
                        if(not entry.activated?,
                          do: "cursor-pointer",
                          else: "cursor-default"
                        )
                      ]}
                    >
                      <%!-- Mismo chip claro que las cards: el logo del catálogo
                           es fill="currentColor" (negro dentro de un <img>). --%>
                      <span class="flex items-center justify-center w-8 h-8 shrink-0 rounded-lg bg-white overflow-hidden">
                        <img
                          :if={entry.logo_url}
                          src={entry.logo_url}
                          alt=""
                          class="w-5 h-5 object-contain"
                          loading="lazy"
                        />
                        <.icon
                          :if={!entry.logo_url}
                          name="hero-server-stack"
                          class="w-4 h-4 text-neutral-600"
                        />
                      </span>

                      <span class="flex-1 min-w-0">
                        <span class="flex items-center gap-2">
                          <span class="font-medium truncate">{entry.name}</span>
                          <code class="text-[10px] text-base-content/40 truncate">
                            {entry.key}
                          </code>
                        </span>
                        <span class="block text-[11px] text-base-content/50 truncate">
                          {entry.base_url || "—"}
                        </span>
                      </span>

                      <span class="flex gap-1 shrink-0 items-center">
                        <span
                          :if={entry.activated?}
                          class="text-[10px] text-success inline-flex items-center gap-0.5"
                        >
                          <.icon name="hero-check-circle" class="w-3 h-3" /> activo
                        </span>
                      </span>
                    </div>

                    <a
                      :if={entry.doc_url}
                      href={entry.doc_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="btn btn-ghost btn-xs shrink-0"
                      id={"docs-#{entry.key}"}
                      title={gettext("Documentation for %{name}", name: entry.name)}
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                    </a>
                  </div>
                </div>

                <div
                  :if={@catalog_results == []}
                  class="text-center py-8 text-base-content/40 text-sm"
                  id="catalog-empty"
                >
                  {gettext("No provider matches the search.")}
                </div>
              </div>

              <p class="text-[11px] text-base-content/40 mt-2 shrink-0" id="catalog-count">
                {gettext("%{shown} of %{total}",
                  shown: length(@catalog_results),
                  total: @catalog_total
                )}
              </p>
            </div>
          </div>
        </div>

        <%!-- Provider form (create / edit) — modal (customs only: catalog
             builtins don't offer the Editar button at all) --%>
        <div :if={@form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_form" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-3xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_provider_id == :new,
                  do: gettext("New provider"),
                  else: gettext("Edit provider")}
              </h2>
              <.form for={@form} id="provider-form" phx-submit="save_provider">
                <div class="space-y-3">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label={gettext("Name")}
                    placeholder="mi-relay"
                    disabled={@editing_provider_builtin?}
                    hint={
                      if @editing_provider_builtin?,
                        do:
                          gettext("Catalog identity — not editable. Only the limits are edited here."),
                        else: gettext("Unique id of the custom provider.")
                    }
                  />
                  <.input
                    field={@form[:base_url]}
                    type="text"
                    label="Base URL"
                    placeholder="https://relay.example.com/v1"
                    disabled={@editing_provider_builtin?}
                    hint="URL base (OpenAI-compatible)."
                  />
                </div>

                <%!-- Limits live on the provider: every API key of this provider
                     inherits them (a credential is just an alias + secret). --%>
                <div class="pt-4 mt-4 border-t border-base-200">
                  <h3 class="text-sm font-semibold mb-1">{gettext("Provider limits")}</h3>
                  <p class="text-xs text-base-content/50 mb-3">
                    {gettext(
                      "They apply to every API key of this provider, which inherits them. Empty = no limit."
                    )}
                  </p>
                  <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5">
                    <.input
                      field={@form[:max_rpm]}
                      type="number"
                      label="Max RPM"
                      hint={gettext("Requests per minute across the provider. Empty = no limit.")}
                    />
                    <.input
                      field={@form[:max_concurrent]}
                      type="number"
                      label={gettext("Max concurrency")}
                      hint={gettext("Concurrent requests across the provider. Empty = no limit.")}
                    />
                    <.input
                      field={@form[:max_concurrent_per_user]}
                      type="number"
                      label={gettext("Max concurrency per user")}
                      hint={gettext("Concurrent cap per user. Empty = no limit.")}
                    />
                    <.input
                      field={@form[:receive_timeout_ms]}
                      type="number"
                      label="Timeout (ms)"
                      hint={
                        gettext("Max wait per response. Empty = global default (%{ms} ms).",
                          ms: ProviderLimits.default_receive_timeout_ms()
                        )
                      }
                    />
                  </div>
                </div>
                <div class="flex gap-2 mt-4 justify-end">
                  <button type="button" phx-click="cancel_form" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-provider-btn">
                    {gettext("Save")}
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Credential form (create / edit) — modal --%>
        <div :if={@credential_form} class="fixed inset-0 z-50 flex items-center justify-center p-4">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_credential" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-2xl">
            <div class="card-body p-6">
              <h2 class="text-lg font-semibold mb-4">
                {if @editing_credential_id,
                  do: gettext("Edit credential"),
                  else: gettext("New credential")}
              </h2>
              <.form for={@credential_form} id="credential-form" phx-submit="save_credential">
                <.input field={@credential_form[:provider_id]} type="hidden" />
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5">
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
                    label={"#{gettext("API key")}#{if @editing_credential_id, do: gettext(" (leave empty = unchanged)"), else: ""}"}
                    placeholder={
                      if @editing_credential_id,
                        do: gettext("sk-... (leave empty to keep)"),
                        else: "sk-..."
                    }
                    hint={
                      if @editing_credential_id,
                        do: gettext("Only if you want to change it."),
                        else: gettext("The token the provider gives you (sk-...).")
                    }
                  />
                </div>
                <div class="flex gap-2 pt-4 mt-5 border-t border-base-200 justify-end">
                  <button type="button" phx-click="cancel_credential" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-credential-btn">
                    {(@editing_credential_id && gettext("Update")) || gettext("Save")}
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <%!-- Capacidades modal: one path per service. Empty inherits — the
             catalog code path when the builtin declares one, else the generic
             adapter default; anything typed overrides it. --%>
        <div
          :if={@paths_form}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          id="paths-modal"
        >
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_paths" />
          <div class="relative card bg-base-100 border border-base-300 shadow-xl w-full max-w-3xl">
            <div class="card-body p-6 max-h-[85vh] overflow-y-auto">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h2 class="text-lg font-semibold">{gettext("Capabilities")}</h2>
                  <p class="text-xs text-base-content/60 mt-1">
                    {gettext("Path of each service of")} <span class="font-medium">{@paths_provider_name}</span>. {gettext(
                      "It resolves as"
                    )}
                    <code>base_url</code> {gettext("+ path; empty = adapter default.")}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="cancel_paths"
                  class="btn btn-ghost btn-sm btn-circle"
                  id="close-paths-modal"
                  aria-label={gettext("Close")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>

              <.form for={@paths_form} id="paths-form" phx-submit="save_paths">
                <.input field={@paths_form[:provider_id]} type="hidden" />
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5 mt-4">
                  <.input
                    :for={service <- @path_service_rows}
                    field={@paths_form[service.key]}
                    type="text"
                    label={service.label}
                    placeholder={service.placeholder}
                    hint={service.hint}
                  />
                </div>
                <div class="flex gap-2 pt-4 mt-5 border-t border-base-200 justify-end">
                  <button type="button" phx-click="cancel_paths" class="btn btn-ghost btn-sm">
                    {gettext("Cancel")}
                  </button>
                  <button type="submit" class="btn btn-primary btn-sm" id="save-paths-btn">
                    {gettext("Save")}
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <div
          :if={@providers == []}
          class="text-center py-12 text-base-content/40"
          id="providers-empty"
        >
          <.icon name="hero-server-stack" class="w-10 h-10 mx-auto mb-2 opacity-40" />
          <p>{gettext("No providers yet.")}</p>
        </div>

        <%!-- Una sola lista, sin tabs: builtin primero y custom al final
             (lo fija el `order_by` de `load_providers/1`). --%>
        <div id="providers" class="grid gap-3 lg:grid-cols-2">
          <div
            :for={provider <- @providers}
            id={"providers-#{provider.id}"}
            class="card bg-base-100 border border-base-300 shadow-sm"
          >
            <div class="card-body p-4">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <div class="flex items-center gap-2">
                    <%!-- Chip claro fijo: los logos del catálogo usan
                         fill="currentColor" y dentro de un <img> eso resuelve a
                         negro — sobre el card oscuro (tema dim) quedaban
                         invisibles. El icono genérico (proveedor sin logo del
                         catálogo, o sea los customs) se pinta oscuro para el
                         mismo chip. --%>
                    <span class="flex items-center justify-center w-7 h-7 shrink-0 rounded-lg bg-white overflow-hidden">
                      <img
                        :if={provider.logo_url}
                        src={provider.logo_url}
                        alt=""
                        class="w-4 h-4 object-contain"
                        loading="lazy"
                      />
                      <.icon
                        :if={!provider.logo_url}
                        name="hero-server-stack"
                        class="w-4 h-4 text-neutral-600"
                      />
                    </span>
                    <h3 class="font-semibold text-base-content">{provider.name}</h3>

                    <span class={[
                      "badge badge-sm",
                      if(provider.status == "active", do: "badge-success", else: "badge-ghost")
                    ]}>
                      {if provider.status == "active",
                        do: gettext("Active"),
                        else: gettext("Disabled")}
                    </span>

                    <a
                      :if={provider.doc_url}
                      href={provider.doc_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="link link-hover text-xs text-base-content/50"
                      id={"provider-docs-#{provider.id}"}
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" /> {gettext("Docs")}
                    </a>
                  </div>
                  <p class="text-xs text-base-content/50 mt-1 font-mono">{provider.base_url}</p>
                  <p class="text-xs text-base-content/50 mt-0.5">
                    {gettext("%{count} credentials", count: length(credentials_for(provider)))}
                  </p>

                  <%!-- Provider-level limits: everything below this line (every
                       key of this provider) inherits them. --%>
                  <div
                    class="mt-2 flex flex-wrap items-center gap-1.5"
                    id={"provider-limits-#{provider.id}"}
                  >
                    <span class="text-[10px] uppercase tracking-wide text-base-content/40">{gettext(
                      "Limits"
                    )}</span>
                    <span class="badge badge-ghost badge-sm" title={gettext("Requests per minute")}>
                      RPM {provider.max_rpm || "∞"}
                    </span>
                    <span
                      class="badge badge-ghost badge-sm"
                      title={gettext("Provider max concurrency")}
                    >
                      Conc. {provider.max_concurrent || "∞"}
                    </span>
                    <span
                      class="badge badge-ghost badge-sm"
                      title={gettext("Max concurrency per user")}
                    >
                      {gettext("Conc./user")} {provider.max_concurrent_per_user || "∞"}
                    </span>
                    <span
                      class="badge badge-ghost badge-sm font-mono"
                      title={gettext("Receive timeout")}
                    >
                      {timeout_label(provider)}
                    </span>
                  </div>
                </div>
                <div class="flex gap-2 items-center">
                  <button
                    phx-click="toggle_provider"
                    phx-value-id={provider.id}
                    class="btn btn-sm btn-ghost"
                    id={"toggle-provider-#{provider.id}"}
                  >
                    {if provider.status == "active", do: gettext("Disable"), else: gettext("Enable")}
                  </button>
                  <%!-- Capacidades: the per-service path overrides (base_url +
                       path). Available on builtins too — paths are operational,
                       not catalog identity. The badge counts the overridden
                       services. --%>
                  <button
                    phx-click="edit_paths"
                    phx-value-id={provider.id}
                    class="btn btn-sm btn-ghost"
                    id={"paths-#{provider.id}"}
                    title={gettext("Configure the path of each capability (base_url + path)")}
                  >
                    <.icon name="hero-adjustments-horizontal" class="w-4 h-4" /> {gettext(
                      "Capabilities"
                    )}
                    <span
                      :if={path_override_count(provider) > 0}
                      class="badge badge-xs badge-primary"
                    >
                      {path_override_count(provider)}
                    </span>
                  </button>
                  <%!-- Builtins are editable too, but ONLY for their limits: the
                       form renders the catalog identity read-only and the
                       changeset drops any change to it. --%>
                  <button
                    phx-click="edit_provider"
                    phx-value-id={provider.id}
                    class="btn btn-sm btn-ghost"
                    id={"edit-#{provider.id}"}
                  >
                    <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
                  </button>
                  <button
                    phx-click="delete_provider"
                    phx-value-id={provider.id}
                    data-confirm={gettext("Delete this provider?")}
                    class="btn btn-sm btn-ghost text-error"
                    id={"delete-#{provider.id}"}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
                  </button>
                </div>
              </div>

              <%!-- Credentials panel — always open --%>
              <div
                class="mt-3 pt-3 border-t border-base-300"
                id={"credentials-panel-#{provider.id}"}
              >
                <div class="flex items-center justify-between mb-2">
                  <h4 class="text-sm font-semibold">{gettext("Credentials")}</h4>
                  <button
                    phx-click="new_credential"
                    phx-value-provider_id={provider.id}
                    class="btn btn-xs btn-ghost"
                    id={"new-credential-#{provider.id}"}
                    title={gettext("Add an API key to this provider")}
                  >
                    <.icon name="hero-plus" class="w-3 h-3" /> {gettext("API key")}
                  </button>
                </div>

                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>{gettext("Alias")}</th>
                        <th>{gettext("Key")}</th>
                        <th>{gettext("In flight")}</th>
                        <th>{gettext("Breaker")}</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={cred <- credentials_for(provider)}
                        id={"credential-#{cred.id}"}
                        class={
                          credential_row_class(cred, Map.get(@breaker_statuses, cred.id, :closed))
                        }
                      >
                        <td>
                          {cred.name || "—"}
                        </td>
                        <td>
                          <code class="text-sm font-mono">{mask_key(cred.api_key_encrypted)}</code>
                        </td>
                        <td>
                          <% inflight = Map.get(@credential_inflight, cred.id, 0) %>
                          <span class={[
                            "badge badge-sm",
                            if(inflight > 0, do: "badge-primary", else: "badge-ghost")
                          ]}>
                            {inflight}
                          </span>
                        </td>
                        <td>
                          <% breaker = Map.get(@breaker_statuses, cred.id, :closed) %>
                          <div class="flex items-center gap-2">
                            <span class={[
                              "badge badge-sm",
                              breaker == :closed && "badge-success",
                              breaker == :open && "badge-error",
                              breaker == :half_open && "badge-warning"
                            ]}>
                              {breaker_label(breaker)}
                            </span>
                            <button
                              :if={breaker != :closed}
                              phx-click="reset_breaker"
                              phx-value-id={cred.id}
                              class="btn btn-xs btn-ghost"
                              id={"reset-breaker-#{cred.id}"}
                            >
                              <.icon name="hero-arrow-path" class="w-3 h-3" /> Reset
                            </button>
                          </div>
                        </td>
                        <td class="text-right">
                          <%= if cred.status == "error" do %>
                            <button
                              phx-click="reactivate_credential"
                              phx-value-id={cred.id}
                              class="btn btn-xs btn-ghost btn-warning"
                              id={"reactivate-credential-#{cred.id}"}
                            >
                              <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Reactivate")}
                            </button>
                          <% else %>
                            <button
                              phx-click="toggle_credential"
                              phx-value-id={cred.id}
                              class="btn btn-xs btn-ghost"
                              id={"toggle-credential-btn-#{cred.id}"}
                              title={
                                if cred.status == "active",
                                  do: gettext("Disable"),
                                  else: gettext("Enable")
                              }
                            >
                              <.icon
                                name={if cred.status == "active", do: "hero-pause", else: "hero-play"}
                                class="w-3 h-3"
                              />
                            </button>
                          <% end %>
                          <button
                            phx-click="edit_credential"
                            phx-value-id={cred.id}
                            class="btn btn-xs btn-ghost"
                            id={"edit-credential-#{cred.id}"}
                          >
                            <.icon name="hero-pencil-square" class="w-3 h-3" /> {gettext("Edit")}
                          </button>
                          <button
                            phx-click="delete_credential"
                            phx-value-id={cred.id}
                            data-confirm={gettext("Delete this credential?")}
                            class="btn btn-xs btn-ghost text-error"
                            id={"delete-credential-#{cred.id}"}
                          >
                            {gettext("Delete")}
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
