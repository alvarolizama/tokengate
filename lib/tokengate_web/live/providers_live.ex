defmodule TokengateWeb.ProvidersLive do
  @moduledoc """
  Admin CRUD for providers — the operator's catalog table.

  One row per provider: identity, status, key counters, model count, the limits
  every key inherits, and the live health of its keys (in-flight + open
  breakers). The API keys themselves live on their own page,
  `TokengateWeb.ProviderKeysLive` (`/catalog/providers/:id/keys`); activating a
  catalog provider navigates there with the alta modal open.

  The provider owns the operational limits (`max_rpm`, `max_concurrent`,
  `max_concurrent_per_user`, `receive_timeout_ms`) and every credential of
  that provider inherits them — a credential is just an alias + API key.
  Those fields are editable for builtins too; their catalog identity isn't.

  Pricing is managed per ModelProvider (model × credential) in the
  Models section, not here.

  Deleting a provider that still serves lanes is blocked with a friendly
  Spanish flash message; the "is it in use" check runs in the context, inside
  the delete transaction and under the provider's row lock, and it counts
  lanes served by the provider's credential pools as well as by its keys.
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

  # Providers pinned to the TOP of the add-provider picker, in this order.
  # Pure UI curation — routing, pricing and capabilities don't read this.
  # Everything else stays alphabetical by name.
  @recommended_provider_keys ~w(openrouter runinfra fireworks-ai)

  # Baseline counters for a provider with no credentials yet: the batched
  # aggregation starts from this shape, so the template never sees a missing key.
  @no_credentials %{ids: [], keys: 0, active: 0, errored: 0}

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
      |> assign(:catalog_modal_open, false)
      |> assign(:catalog_query, "")
      |> assign(:provider_step, "pick")
      |> assign(:provider_steps, provider_steps(:new))
      |> assign(:provider_step_error, nil)
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
        {:halt, put_flash(socket, :error, gettext("Not authorized."))}
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
    # Every provider in one query. The per-row numbers (keys, models, breaker,
    # in-flight) come from the batched lookups below — never from a query
    # inside the template loop. Builtin primero, custom al final (`false`
    # ordena antes que `true` en Postgres) y, dentro de cada grupo, por nombre.
    providers =
      from(p in Provider,
        order_by: [asc: p.source == "custom", asc: p.name]
      )
      |> Repo.all()

    # One sweep over every credential: the per-provider counters and the live
    # breaker/in-flight lookups all read from this map.
    credential_stats =
      from(c in Credential, select: {c.provider_id, c.id, c.status})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {provider_id, cred_id, status}, acc ->
        entry = Map.get(acc, provider_id, @no_credentials)

        entry = %{
          ids: [cred_id | entry.ids],
          keys: entry.keys + 1,
          active: entry.active + if(status == "active", do: 1, else: 0),
          errored: entry.errored + if(status == "error", do: 1, else: 0)
        }

        Map.put(acc, provider_id, entry)
      end)

    # Only providers in use: those with at least one credential. Seeded
    # builtins without API keys stay invisible until a credential attaches to
    # them — the "Add provider" picker is the way in.
    providers =
      Enum.filter(providers, fn provider ->
        credential_stats(provider.id, credential_stats).keys > 0 or provider.source == "custom"
      end)

    # model_providers hang off the credential, so one join answers the count
    # for every provider at once.
    provider_model_counts =
      from(mp in ModelProvider,
        join: c in assoc(mp, :credential),
        group_by: c.provider_id,
        select: {c.provider_id, count(mp.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Circuit breaker state for every credential in one Registry sweep
    # (instead of one lookup + GenServer call per credential). Unknown
    # credentials simply don't appear — the template must default to :closed.
    breaker_statuses =
      Tokengate.Routing.CircuitBreakerManager.status_all()
      |> then(fn all ->
        for {_provider_id, stats} <- credential_stats,
            id <- stats.ids,
            into: %{},
            do: {id, Map.get(all, id, :closed)}
      end)

    socket
    |> assign(:providers, providers)
    |> assign(:providers_empty?, providers == [])
    |> assign(:credential_stats, credential_stats)
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
          activated?: MapSet.member?(activated_keys, row.key),
          recommended?: row.key in @recommended_provider_keys
        }
      end)
      |> Enum.sort_by(fn entry ->
        {recommended_rank(entry.key), entry.name || entry.key}
      end)

    socket
    |> assign(:catalog_entries, entries)
    |> assign(:catalog_total, length(entries))
    |> assign(:catalog_results, entries)
  end

  # Sort rank: recommended keys keep their pinned order (0, 1, 2…); everything
  # else ranks after them and falls back to the name ordering.
  defp recommended_rank(key) do
    case Enum.find_index(@recommended_provider_keys, &(&1 == key)) do
      nil -> length(@recommended_provider_keys)
      index -> index
    end
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
  # Adds a custom provider: no catalog entry exists for it, so the wizard asks
  # for the base URL, its capabilities and its limits. Dialect and paths stay
  # code: dialect defaults to openai, paths are the per-capability overrides
  # (the "capacidades" modal on the card).
  #
  # "Custom provider" is step 1 → 2 of the same modal: the wizard stays open and
  # keeps what was typed if the operator walks back to the picker and returns.
  def handle_event("new_custom_provider", _params, socket) do
    socket =
      case socket.assigns do
        %{editing_provider_id: :new, form: %Phoenix.HTML.Form{}} ->
          socket

        _ ->
          changeset =
            Providers.change_provider(%Provider{
              source: "custom",
              dialect: "openai"
            })

          socket
          |> assign(:form, to_form(changeset, as: :provider))
          |> assign(:editing_provider_id, :new)
          |> assign(:editing_provider_builtin?, false)
      end

    {:noreply,
     socket
     |> assign(:catalog_modal_open, true)
     |> assign(:provider_steps, provider_steps(:new))
     |> assign(:provider_step, "identity")
     |> assign(:provider_step_error, nil)}
  end

  # Opens the add-provider wizard on its pick step — the "Agregar proveedor"
  # entry point (the old dropdown could not scale to a few hundred providers).
  # Abre en limpio: el wizard no arrastra el formulario de la vez anterior.
  def handle_event("open_catalog_modal", _params, socket) do
    {:noreply,
     socket
     |> close_provider_wizard()
     |> assign(:catalog_modal_open, true)
     |> filter_catalog("")}
  end

  # Escape / click-away / ✕ of the wizard's pick step and its own close button
  # land here; they close the whole wizard, not just one step.
  def handle_event("close_catalog_modal", _params, socket) do
    {:noreply, close_provider_wizard(socket)}
  end

  # Search over name and models.dev id. In memory: the mirror is a few hundred
  # rows, so every keystroke is instant and costs no query.
  def handle_event("search_catalog", params, socket) do
    {:noreply, filter_catalog(socket, params["query"] || "")}
  end

  # Attaching an API key IS what activates a catalog provider, and keys live on
  # their own page: jump to it with the alta modal already open. Builtin rows
  # are materialized at boot, so the row exists before its first key.
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
            {:noreply,
             push_navigate(socket, to: ~p"/catalog/providers/#{provider.id}/keys?new=1")}
        end
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, close_provider_wizard(socket)}
  end

  ## Events — capability paths ----------------------------------------------

  # Opens the Capacidades modal: one path input per service, pre-filled with
  # the provider's own overrides — an empty input means "inherit", which is
  # the normal state.
  def handle_event("edit_paths", %{"id" => provider_id}, socket) do
    case fetch_provider(provider_id) do
      {:ok, provider} ->
        {:noreply, open_paths_modal(socket, provider, ProviderPaths.overrides(provider))}

      :error ->
        {:noreply, provider_gone(socket)}
    end
  end

  def handle_event("cancel_paths", _params, socket) do
    {:noreply, close_paths_modal(socket)}
  end

  # An empty input is dropped by `normalize/1`, so "leave it blank" and "clear
  # an override" are the same gesture and the column keeps one shape.
  #
  # The id comes from the modal's assign, not from the payload: Cancel clears
  # it, and a submit already in flight lands right after — that path must be a
  # no-op, never a `get_provider!(nil)` that takes the LiveView down.
  def handle_event("save_paths", %{"paths" => params}, socket) do
    submitted = Map.delete(params, "provider_id")

    case fetch_provider(socket.assigns.paths_provider_id) do
      :error ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The provider no longer exists."))
         |> close_paths_modal()
         |> load_providers()}

      {:ok, provider} ->
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
  end

  # Editing a builtin is allowed on purpose: its operational limits belong to
  # the operator while its identity (name, base_url) stays catalog-owned — the
  # form renders those read-only and the changeset discards any change to them
  # anyway. So a builtin lands on the limits step (the only thing it can edit,
  # with no step indicator); a custom lands on identity, where its name and
  # base URL live, and walks forward to the limits.
  def handle_event("edit_provider", %{"id" => provider_id}, socket) do
    case fetch_provider(provider_id) do
      {:ok, provider} ->
        changeset = Providers.change_provider(provider)
        builtin? = provider.source == "builtin"
        mode = if builtin?, do: :limits_only, else: :edit

        {:noreply,
         socket
         |> assign(:form, to_form(changeset, as: :provider))
         |> assign(:editing_provider_id, provider.id)
         |> assign(:editing_provider_builtin?, builtin?)
         |> assign(:provider_steps, provider_steps(mode))
         |> assign(:provider_step, if(builtin?, do: "limits", else: "identity"))
         |> assign(:provider_step_error, nil)}

      :error ->
        {:noreply, provider_gone(socket)}
    end
  end

  def handle_event("save_provider", %{"provider" => provider_params}, socket) do
    save_provider(
      socket,
      socket.assigns.editing_provider_id,
      normalize_capabilities(provider_params)
    )
  end

  # Wizard navigation. The buttons live in the modal footer (outside the form),
  # so "Next" carries no payload: the draft changeset kept by `provider_draft`
  # is what gets validated. Nothing is persisted until Save on the last step.
  def handle_event("provider_next", _params, socket) do
    case socket.assigns.provider_step do
      "identity" -> {:noreply, provider_next_identity(socket)}
      _step -> {:noreply, socket}
    end
  end

  # Back never resets the form: the steps share one changeset, so the values
  # typed on a later step are still there when the operator returns.
  def handle_event("provider_back", _params, socket) do
    {:noreply,
     socket
     |> assign(:provider_step, previous_provider_step(socket.assigns))
     |> assign(:provider_step_error, nil)}
  end

  # Clicking a step crumb jumps to that step (tab-style). Save validates the whole
  # changeset, so navigating freely between steps is safe.
  def handle_event("goto_provider_step", %{"step" => step}, socket) do
    if step in Enum.map(socket.assigns.provider_steps, fn {key, _} -> key end) do
      {:noreply,
       socket
       |> assign(:provider_step, step)
       |> assign(:provider_step_error, nil)}
    else
      {:noreply, socket}
    end
  end

  # Keeps the typed values on the server between steps. Every step of the form
  # is rendered (the inactive one hidden), so the payload carries the whole
  # provider, not just the visible inputs.
  def handle_event("provider_draft", %{"provider" => params}, socket) do
    case socket.assigns.form do
      %Phoenix.HTML.Form{source: %Ecto.Changeset{} = current} ->
        changeset =
          current.data
          |> Providers.change_provider(normalize_capabilities(params))
          |> keep_action(current.action)

        {:noreply, assign(socket, :form, to_form(changeset, as: :provider))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("provider_draft", _params, socket), do: {:noreply, socket}

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
    case fetch_provider(provider_id) do
      :error ->
        {:noreply, provider_gone(socket)}

      {:ok, provider} ->
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
  end

  # A client can post any event it wants over the socket: an event with no
  # clause would raise FunctionClauseError and take the LiveView down with the
  # page half rendered. Unknown events are a no-op.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Private helpers — provider save --------------------------------------

  # The capabilities group submits a hidden empty sentinel so "uncheck
  # everything" reaches the server as an explicit empty list — the changeset
  # only understands capability names, so the sentinel is dropped here. An
  # empty set is legal: routing falls back to chat (effective_capabilities/1).
  # The binary clauses cover a client posting the field without the [] suffix
  # ("" normalizes to [], a bare value wraps into a one-element list).
  defp normalize_capabilities(%{"capabilities" => caps} = params) when is_list(caps) do
    Map.put(params, "capabilities", Enum.reject(caps, &(&1 == "")))
  end

  defp normalize_capabilities(%{"capabilities" => ""} = params) do
    normalize_capabilities(Map.put(params, "capabilities", []))
  end

  defp normalize_capabilities(%{"capabilities" => caps} = params) when is_binary(caps) do
    normalize_capabilities(Map.put(params, "capabilities", [caps]))
  end

  defp normalize_capabilities(params), do: params

  # Client-supplied ids are untrusted. A malformed one raises
  # `Ecto.Query.CastError` inside `Repo.get` and a well-formed-but-gone one
  # raises `Ecto.NoResultsError` inside `get_provider!/1`; either kills the
  # LiveView mid-request. Every handler that takes an id from the socket casts
  # first and treats "no row" as a flash, not an exception.
  defp fetch_provider(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Provider{} = provider <- Repo.get(Provider, uuid) do
      {:ok, provider}
    else
      _ -> :error
    end
  end

  # Drops the row from the table (it is gone) and says why the click did
  # nothing.
  defp provider_gone(socket) do
    socket
    |> put_flash(:error, gettext("The provider no longer exists."))
    |> load_providers()
  end

  # The "is it in use" answer is decided by the context INSIDE the delete
  # transaction and under the provider's row lock: the check cannot go stale
  # between the two statements, and a lane served by one of the provider's
  # credential pools counts too.
  defp delete_provider(socket, provider) do
    # Slow deletes surface as exceptions, not {:error, _}: a client-side
    # timeout raises DBConnection.ConnectionError; a server-side
    # statement_timeout or deadlock raises Postgrex.Error (query_canceled /
    # 40P01). Without this the LiveView crashes and the user sees nothing.
    try do
      case Providers.delete_provider_if_unused(provider) do
        {:ok, _} ->
          audit(socket, "provider.delete", "provider", provider.id, %{"name" => provider.name})

          {:noreply,
           socket
           |> put_flash(:info, gettext("Provider deleted."))
           |> load_providers()}

        {:error, :in_use} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Cannot delete: the provider is in use by one or more models.")
           )}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("The provider no longer exists."))
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

  # Capabilities for a custom come straight from the form (there is no catalog
  # entry to derive them from); builtins get them from `Catalog`.
  # A submit already in flight lands right after Cancel cleared the editing
  # id: no-op instead of a FunctionClauseError that would lose the form.
  defp save_provider(socket, nil, _provider_params), do: {:noreply, socket}

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
    case fetch_provider(provider_id) do
      :error ->
        # The row is gone (another admin deleted it while this form was open):
        # drop the form and say so instead of raising NoResultsError.
        {:noreply,
         socket
         |> put_flash(:error, gettext("The provider no longer exists."))
         |> assign(:form, nil)
         |> assign(:editing_provider_id, nil)
         |> load_providers()}

      {:ok, provider} ->
        case Providers.update_provider(provider, provider_params) do
          {:ok, updated} ->
            audit(socket, "provider.update", "provider", updated.id, %{
              "name" => updated.name,
              "changes" =>
                Map.take(provider_params, [
                  "name",
                  "status",
                  "base_url",
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

  ## Private helpers — provider wizard -------------------------------------

  # Steps of the provider modal. Alta starts at the catalog picker; a custom
  # edit starts at identity (name + base URL are its editable identity) and a
  # builtin edit has a single step — its catalog identity is read-only, so a
  # step indicator would only show a step that leads nowhere.
  defp provider_steps(:new) do
    [
      {"pick", gettext("Provider")},
      {"identity", gettext("Identity")},
      {"limits", gettext("Limits")}
    ]
  end

  defp provider_steps(:edit) do
    [{"identity", gettext("Identity")}, {"limits", gettext("Limits")}]
  end

  defp provider_steps(:limits_only), do: [{"limits", gettext("Limits")}]

  defp provider_modal_title(:new), do: gettext("New provider")
  defp provider_modal_title(nil), do: gettext("Add provider")
  defp provider_modal_title(_provider_id), do: gettext("Edit provider")

  defp first_step([{key, _label} | _rest]), do: key

  # Closing the modal drops every piece of wizard state: a half-typed provider
  # must not come back when the modal is reopened.
  defp close_provider_wizard(socket) do
    socket
    |> assign(:catalog_modal_open, false)
    |> assign(:form, nil)
    |> assign(:editing_provider_id, nil)
    |> assign(:editing_provider_builtin?, false)
    |> assign(:provider_steps, provider_steps(:new))
    |> assign(:provider_step, "pick")
    |> assign(:provider_step_error, nil)
  end

  # Step validation for identity: the provider must be nameable (name + a real
  # http(s) base URL) and serve at least one capability before the operator
  # moves on to the limits. A rejected Next shows the reason and stays put.
  defp provider_next_identity(%{assigns: %{form: nil}} = socket), do: socket

  defp provider_next_identity(socket) do
    changeset = socket.assigns.form.source
    name = blank_to_nil(Ecto.Changeset.get_field(changeset, :name))
    base_url = blank_to_nil(Ecto.Changeset.get_field(changeset, :base_url))
    capabilities = Ecto.Changeset.get_field(changeset, :capabilities) || []

    cond do
      is_nil(name) or is_nil(base_url) ->
        reject_identity_step(socket, changeset, gettext("Name and Base URL are required."))

      not valid_base_url?(base_url) ->
        reject_identity_step(
          socket,
          changeset,
          gettext("Base URL must be a valid http(s) URL.")
        )

      capabilities == [] ->
        reject_identity_step(
          socket,
          changeset,
          gettext("Pick at least one capability to continue.")
        )

      true ->
        socket
        |> assign(:provider_step_error, nil)
        |> assign(:provider_step, "limits")
    end
  end

  # `action: :validate` is what makes the per-field messages render under the
  # inputs; without it the changeset already has the errors but hides them.
  defp reject_identity_step(socket, changeset, message) do
    socket
    |> assign(:form, to_form(%{changeset | action: :validate}, as: :provider))
    |> assign(:provider_step_error, message)
  end

  defp previous_provider_step(%{provider_steps: steps, provider_step: current}) do
    keys = Enum.map(steps, &elem(&1, 0))
    index = Enum.find_index(keys, &(&1 == current)) || 0

    Enum.at(keys, max(index - 1, 0))
  end

  defp keep_action(changeset, nil), do: changeset
  defp keep_action(changeset, action), do: %{changeset | action: action}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # Base URL is the only place a custom declares where it answers: a typo here
  # fails every request later, so the wizard refuses it before the limits step.
  defp valid_base_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

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
      0 ->
        gettext("Paths reset: every capability falls back to its default.")

      n ->
        ngettext(
          "Paths updated (%{count} override).",
          "Paths updated (%{count} overrides).",
          n,
          count: n
        )
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

  @doc "Key counters of one provider (from the batched stats map)."
  def credential_stats(provider_id, stats), do: Map.get(stats, provider_id, @no_credentials)

  @doc """
  Health of one provider, aggregated over its keys: how many of its circuit
  breakers are open (or half-open) and how many upstream requests are in flight
  right now. Both come from live in-memory state, not from a query.
  """
  def provider_health(provider_id, stats, breaker_statuses, inflight) do
    ids = credential_stats(provider_id, stats).ids

    %{
      open: Enum.count(ids, &(Map.get(breaker_statuses, &1, :closed) in [:open, :half_open])),
      inflight: Enum.reduce(ids, 0, fn id, acc -> Map.get(inflight, id, 0) + acc end)
    }
  end

  @doc "How many capabilities this provider overrides — the badge on its button."
  def path_override_count(provider), do: map_size(ProviderPaths.overrides(provider))

  # UI labels for the capabilities a custom can declare — the same picker
  # labels the model wizard uses (ModelsLive.model_type_choices/0):
  # capabilities and model types are one vocabulary. The VALUES come from
  # `Catalog.capabilities/0`, so the form can never offer a value the
  # changeset would reject; a capability without a label is not offered yet
  # (the vocabulary guard test in ProvidersLiveTest fails loudly on drift).
  @doc "The capabilities a custom can declare, in Catalog order: `{label, value, icon}`."
  @spec capability_choices() :: [{String.t(), String.t(), String.t()}]
  def capability_choices do
    Enum.flat_map(Catalog.capabilities(), fn value ->
      case value do
        "llm" -> [{gettext("LLM (chat)"), value, "hero-chat-bubble-left-right"}]
        "embedding" -> [{gettext("Embedding"), value, "hero-squares-2x2"}]
        "decision" -> [{gettext("Decisions"), value, "hero-scale"}]
        "rerank" -> [{gettext("Rerank"), value, "hero-arrows-up-down"}]
        "stt" -> [{gettext("Transcription"), value, "hero-microphone"}]
        "tts" -> [{gettext("Speech"), value, "hero-speaker-wave"}]
        "image" -> [{gettext("Images"), value, "hero-photo"}]
        _ -> []
      end
    end)
  end

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

  @doc "Format a decimal for display."
  def fmt_dec(nil), do: "—"
  def fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  def fmt_dec(n), do: to_string(n)

  @doc "Format a datetime for display."
  def fmt_dt(nil, _timezone), do: "—"

  def fmt_dt(%DateTime{} = dt, timezone) do
    TokengateWeb.TimezoneHelper.format_datetime_iso(dt, timezone)
  end

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

        <%!-- Add/edit provider: one modal, a 2–3 step wizard. Step 1 (pick) is
             the searchable models.dev mirror — a row activates its provider on
             its own keys page, "Custom provider" continues here. Step 2
             (identity) is name + base URL + capabilities; step 3 (limits) the
             caps every key inherits. Both form steps stay rendered (hidden when
             inactive) so Back/Next never lose what was typed and Save submits
             the whole form. Editing a custom enters at identity; a builtin only
             has limits to edit, so it enters there with no step indicator.
             Rows without base URL, with a templated URL or without an
             OpenAI-compatible dialect are filtered out of the picker; rows
             already carrying a credential render as activated. --%>
        <.modal
          :if={@catalog_modal_open || @form}
          id="provider-wizard-modal"
          title={provider_modal_title(@editing_provider_id)}
          on_close="cancel_form"
          max_w="max-w-3xl"
          steps={if length(@provider_steps) > 1, do: @provider_steps, else: nil}
          current_step={@provider_step}
          step_click="goto_provider_step"
        >
          <div class="pr-1">
            <%= if @provider_step == "pick" do %>
              <p class="text-xs text-base-content/60 mb-3" id="catalog-subtitle">
                {gettext(
                  "models.dev catalog (%{count} providers). Picking one opens its credential.",
                  count: @catalog_total
                )}
              </p>

              <form
                id="catalog-search-form"
                phx-change="search_catalog"
                phx-submit="search_catalog"
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
                class="text-left px-3 py-2 mt-2 w-full rounded-lg border border-dashed border-base-300 hover:bg-base-200 flex justify-between items-center"
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
                class="overflow-y-auto max-h-[45vh] -mx-1 px-1"
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
                          data-logo
                          class="w-5 h-5 object-contain"
                          loading="lazy"
                        />
                        <.icon
                          name="hero-server-stack"
                          class={["w-4 h-4 text-neutral-600", entry.logo_url && "hidden"]}
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
                        <%!-- Mismo lenguaje de marcador que "activo": texto chico +
                             icono, no un badge — la fila del picker no lleva
                             badges (las capabilities no son chrome del picker). --%>
                        <span
                          :if={entry.recommended?}
                          class="text-[10px] text-primary inline-flex items-center gap-0.5"
                        >
                          <.icon name="hero-star" class="w-3 h-3" /> {gettext("recommended")}
                        </span>

                        <span
                          :if={entry.activated?}
                          class="text-[10px] text-success inline-flex items-center gap-0.5"
                        >
                          <.icon name="hero-check-circle" class="w-3 h-3" /> {gettext("active")}
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

              <p class="text-[11px] text-base-content/40 mt-2" id="catalog-count">
                {gettext("%{shown} of %{total}",
                  shown: length(@catalog_results),
                  total: @catalog_total
                )}
              </p>
            <% end %>

            <%!-- Identity + limits: one form, one submit. The inactive step is
                 hidden, not dropped, so Save carries every field regardless of
                 the step the operator is standing on. --%>
            <.form
              :if={@form}
              for={@form}
              id="provider-form"
              phx-change="provider_draft"
              phx-submit="save_provider"
            >
              <div
                class={if(@provider_step == "identity", do: "space-y-3", else: "hidden")}
                id="provider-step-identity"
              >
                <p :if={@provider_step_error} id="provider-step-error" class="text-sm text-error">
                  {@provider_step_error}
                </p>
                <div class="space-y-3">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label={gettext("Name")}
                    placeholder="mi-relay"
                    phx-mounted={JS.focus()}
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
                    hint={gettext("URL base (OpenAI-compatible).")}
                  />
                </div>

                <%!-- Capabilities: what the upstream can serve. Identity is
                     catalog-owned for builtins (the changeset discards the
                     change anyway), so the group renders for customs only. --%>
                <div :if={!@editing_provider_builtin?} class="pt-4 mt-4 border-t border-base-200">
                  <h3 class="text-sm font-semibold mb-1">{gettext("Capabilities")}</h3>
                  <p class="text-xs text-base-content/50 mb-3">
                    {gettext("What this provider can serve. Nothing checked = chat only.")}
                  </p>
                  <input type="hidden" name="provider[capabilities][]" value="" />
                  <div id="provider-capabilities" class="grid grid-cols-2 sm:grid-cols-3 gap-y-2">
                    <label
                      :for={{label, value, icon} <- capability_choices()}
                      class="flex items-center gap-2 cursor-pointer"
                    >
                      <input
                        type="checkbox"
                        name="provider[capabilities][]"
                        value={value}
                        checked={value in (@form[:capabilities].value || [])}
                        class="checkbox checkbox-sm"
                      />
                      <.icon name={icon} class="w-4 h-4 opacity-70" />
                      <span class="text-sm">{label}</span>
                    </label>
                  </div>
                </div>
              </div>

              <div
                class={if(@provider_step == "limits", do: "space-y-3", else: "hidden")}
                id="provider-step-limits"
              >
                <%!-- Limits live on the provider: every API key of this provider
                     inherits them (a credential is just an alias + secret). --%>
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
            </.form>
          </div>

          <:footer>
            <div class="mr-auto">
              <button
                type="button"
                phx-click="cancel_form"
                id="provider-cancel-btn"
                class="btn btn-ghost btn-sm"
              >
                {gettext("Cancel")}
              </button>
            </div>
            <button
              :if={@provider_step != first_step(@provider_steps)}
              type="button"
              phx-click="provider_back"
              id="provider-back-btn"
              class="btn btn-ghost btn-sm"
            >
              {gettext("Back")}
            </button>
            <button
              :if={@provider_step == "identity"}
              type="button"
              phx-click="provider_next"
              id="provider-next-btn"
              class="btn btn-primary btn-sm"
            >
              {gettext("Next")}
            </button>
            <button
              :if={@provider_step == "limits" and @form}
              type="submit"
              form="provider-form"
              id="save-provider-btn"
              class="btn btn-primary btn-sm"
            >
              {gettext("Save")}
            </button>
          </:footer>
        </.modal>

        <%!-- Capacidades modal: one path per service. Empty inherits — the
             catalog code path when the builtin declares one, else the generic
             adapter default; anything typed overrides it. Same .modal as the
             rest, no steps: it is a single short form. --%>
        <.modal
          :if={@paths_form}
          id="paths-modal"
          title={gettext("Capabilities")}
          on_close="cancel_paths"
          max_w="max-w-3xl"
        >
          <div class="pr-1">
            <p class="text-xs text-base-content/60 mb-3">
              {gettext("Path of each service of")} <span class="font-medium">{@paths_provider_name}</span>. {gettext(
                "It resolves as"
              )}
              <code>base_url</code> {gettext("+ path; empty = adapter default.")}
            </p>

            <.form for={@paths_form} id="paths-form" phx-submit="save_paths">
              <.input field={@paths_form[:provider_id]} type="hidden" />
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-5">
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
        </.modal>

        <%!-- Una sola lista en TABLA, sin tabs: builtin primero y custom al
             final (lo fija el `order_by` de `load_providers/1`). Las API keys
             no viven aquí: cada fila lleva a /catalog/providers/:id/keys. --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm overflow-x-auto">
          <.table
            id="providers"
            rows={@providers}
            row_id={fn provider -> "providers-#{provider.id}" end}
            row_class="align-top"
            empty?={@providers_empty?}
          >
            <:col :let={provider} label={gettext("Provider")}>
              <div class="flex items-center gap-2">
                <%!-- Chip claro fijo: los logos del catálogo usan
                     fill="currentColor" y dentro de un <img> eso resuelve a
                     negro — sobre el tema oscuro (dim) quedaban
                     invisibles. El icono genérico (proveedor sin logo del
                     catálogo, o sea los customs) se pinta oscuro para el
                     mismo chip. --%>
                <span class="flex items-center justify-center w-7 h-7 shrink-0 rounded-lg bg-white overflow-hidden">
                  <img
                    :if={provider.logo_url}
                    src={provider.logo_url}
                    alt=""
                    data-logo
                    class="w-4 h-4 object-contain"
                    loading="lazy"
                  />
                  <.icon
                    name="hero-server-stack"
                    class={["w-4 h-4 text-neutral-600", provider.logo_url && "hidden"]}
                  />
                </span>
                <div class="min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="font-medium truncate">{provider.name}</span>
                    <code :if={provider.key} class="text-[10px] text-base-content/40 truncate">
                      {provider.key}
                    </code>
                    <a
                      :if={provider.doc_url}
                      href={provider.doc_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="link link-hover text-base-content/50 shrink-0"
                      id={"provider-docs-#{provider.id}"}
                      title={gettext("Documentation")}
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                    </a>
                  </div>
                  <p class="text-xs text-base-content/50 font-mono truncate max-w-[22rem]">
                    {provider.base_url}
                  </p>
                </div>
              </div>
            </:col>
            <:col :let={provider} label={gettext("Status")}>
              <span class={[
                "badge badge-sm",
                if(provider.status == "active", do: "badge-success", else: "badge-ghost")
              ]}>
                {if provider.status == "active",
                  do: gettext("Active"),
                  else: gettext("Disabled")}
              </span>
            </:col>
            <:col
              :let={provider}
              label={gettext("Keys")}
              align="right"
              tooltip={gettext("Manage the API keys of this provider")}
            >
              <% stats = credential_stats(provider.id, @credential_stats) %>
              <.link
                navigate={~p"/catalog/providers/#{provider.id}/keys"}
                class="link link-hover whitespace-nowrap inline-flex items-center gap-1"
                id={"provider-keys-#{provider.id}"}
                title={gettext("Manage the API keys of this provider")}
              >
                <.icon name="hero-key" class="w-3 h-3" /> {stats.keys}
              </.link>
              <%!-- Only the exception gets a line of its own: a healthy
                   provider reads as a single number. --%>
              <p :if={stats.errored > 0} class="text-[11px] text-error font-semibold">
                {gettext("%{count} in error", count: stats.errored)}
              </p>
            </:col>
            <:col :let={provider} label={gettext("Models")} align="right">
              <span class="badge badge-ghost badge-sm">
                {model_count(provider.id, @provider_model_counts)}
              </span>
            </:col>
            <%!-- Provider-level limits: every key of this provider inherits
                 them; they are edited here, never per key. --%>
            <:col :let={provider} label={gettext("Limits")}>
              <div
                class="text-[11px] leading-snug text-base-content/60 whitespace-nowrap"
                id={"provider-limits-#{provider.id}"}
              >
                <div>
                  RPM {provider.max_rpm || "∞"} · Conc. {provider.max_concurrent || "∞"}
                </div>
                <div>
                  {gettext("Conc./user")} {provider.max_concurrent_per_user || "∞"} · {timeout_label(
                    provider
                  )}
                </div>
              </div>
            </:col>
            <:col
              :let={provider}
              label={gettext("Health")}
              tooltip={gettext("Requests in flight across this provider's keys")}
            >
              <% health =
                provider_health(
                  provider.id,
                  @credential_stats,
                  @breaker_statuses,
                  @credential_inflight
                ) %>
              <div class="flex items-center gap-1.5">
                <span
                  class={[
                    "badge badge-sm gap-1",
                    if(health.inflight > 0, do: "badge-primary", else: "badge-ghost")
                  ]}
                  title={gettext("Requests in flight across this provider's keys")}
                  id={"provider-inflight-#{provider.id}"}
                >
                  <.icon name="hero-bolt" class="w-3 h-3" /> {health.inflight}
                </span>
                <span
                  :if={health.open > 0}
                  class="badge badge-sm badge-error gap-1"
                  title={gettext("Keys whose circuit breaker is open")}
                  id={"provider-breaker-#{provider.id}"}
                >
                  <.icon name="hero-exclamation-triangle" class="w-3 h-3" /> {health.open}
                </span>
              </div>
            </:col>
            <:action :let={provider}>
              <button
                phx-click="toggle_provider"
                phx-value-id={provider.id}
                class="btn btn-sm btn-ghost px-2"
                id={"toggle-provider-#{provider.id}"}
                title={
                  if provider.status == "active",
                    do: gettext("Disable"),
                    else: gettext("Enable")
                }
                aria-label={
                  if provider.status == "active",
                    do: gettext("Disable"),
                    else: gettext("Enable")
                }
              >
                <.icon
                  name={if provider.status == "active", do: "hero-pause", else: "hero-play"}
                  class="w-4 h-4"
                />
              </button>
              <%!-- Capacidades: the per-service path overrides (base_url +
                   path). Available on builtins too — paths are operational,
                   not catalog identity. The badge counts the overridden
                   services. --%>
              <button
                phx-click="edit_paths"
                phx-value-id={provider.id}
                class="btn btn-sm btn-ghost px-2"
                id={"paths-#{provider.id}"}
                title={gettext("Configure the path of each capability (base_url + path)")}
                aria-label={gettext("Capabilities")}
              >
                <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
                <span :if={path_override_count(provider) > 0} class="badge badge-xs badge-primary">
                  {path_override_count(provider)}
                </span>
              </button>
              <%!-- Builtins are editable too, but ONLY for their limits: the
                   form renders the catalog identity read-only and the
                   changeset drops any change to it. --%>
              <button
                phx-click="edit_provider"
                phx-value-id={provider.id}
                class="btn btn-sm btn-ghost px-2"
                id={"edit-#{provider.id}"}
                title={gettext("Edit")}
                aria-label={gettext("Edit")}
              >
                <.icon name="hero-pencil-square" class="w-4 h-4" />
              </button>
              <button
                phx-click="delete_provider"
                phx-value-id={provider.id}
                data-confirm={gettext("Delete this provider?")}
                class="btn btn-sm btn-ghost px-2 text-error"
                id={"delete-#{provider.id}"}
                title={gettext("Delete")}
                aria-label={gettext("Delete")}
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </:action>
            <:empty>
              <.icon name="hero-server-stack" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{gettext("No providers yet.")}</p>
            </:empty>
          </.table>
        </div>
      </div>
    </Layouts.dashboard>
    """
  end
end
