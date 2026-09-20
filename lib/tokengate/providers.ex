defmodule Tokengate.Providers do
  @moduledoc """
  The Providers context.

  Manages the routing domain: providers, credentials, models, model
  providers, and group/member model grants.

  ## Cost model (since 2026-07-30)

  Per-provider pricing rows (`model_pricing`) and per-model market prices
  have been removed. `provider_cost_usd` is whatever the upstream reports
  in its response body (`usage.cost` for OpenAI-compatible gateways).

  All `belongs_to` references to `Tokengate.Accounts.*` modules resolve at
  runtime — the Accounts context may not be compiled when this module is.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Repo

  alias Tokengate.Providers.{
    Provider,
    Credential,
    Model,
    ModelProvider,
    ServiceModel,
    GroupModel,
    GroupMemberExtraModel,
    GroupMemberDeniedModel,
    CatalogProvider,
    CatalogRefreshWorker,
    CatalogSyncState,
    Lab
  }

  # ---------------------------------------------------------------------------
  # Providers
  # ---------------------------------------------------------------------------

  def list_providers, do: Repo.all(Provider)

  @doc """
  Capacidades EFECTIVAS de un proveedor: lo que realmente puede servir.

    * **builtin** — las declaradas en código (`Catalog.capabilities/1`), que es
      lo que `CatalogSync` copia a la fila. Un builtin sin entrada se trata como
      chat, igual que en el catálogo.
    * **custom** — las de su propia fila (`providers.capabilities`), que el
      operador elige al crearlo.

  Nunca devuelve `[]`: sin dato, el proveedor es chat. Eso mantiene un único
  significado para "no declara nada" en todo el sistema.
  """
  @spec effective_capabilities(Provider.t() | map()) :: [String.t()]
  def effective_capabilities(%Provider{source: "builtin", key: key}) when is_binary(key) do
    case Tokengate.Providers.Catalog.capabilities(key) do
      [] -> ["llm"]
      caps -> caps
    end
  end

  def effective_capabilities(%Provider{capabilities: caps}) when is_list(caps) and caps != [] do
    caps
  end

  def effective_capabilities(_provider), do: ["llm"]

  @doc "True cuando el proveedor declara la capability `type`."
  @spec declares?(Provider.t() | map(), String.t()) :: boolean()
  def declares?(provider, type), do: type in effective_capabilities(provider)

  @doc """
  Los proveedores activos que declaran `type`.

  Es el paso "proveedor" del modal de modelo: elegido el TIPO, sólo tiene
  sentido ofrecer quien puede servir ese servicio — un `fireworks-ai` no sirve
  `image`, y ofrecerlo produce un callejón sin salida. Las credenciales viajan
  preloadeadas porque la fila del selector muestra cuántas keys tiene.
  """
  @spec providers_declaring(String.t()) :: [Provider.t()]
  def providers_declaring(type) when is_binary(type) do
    from(p in Provider,
      where: p.status == "active",
      order_by: [asc: p.name],
      preload: [:credentials]
    )
    |> Repo.all()
    |> Enum.filter(&declares?(&1, type))
  end

  @doc """
  Purga del catálogo **sin uso**: borra modelos sin despliegues
  (`model_providers`) y proveedores sin credenciales ni despliegues — es
  decir, registros que no sirven tráfico y de los que no queda nada que
  conservar. Para el reset de Mantenimiento ("dejar todo en cero manteniendo
  lo activo"): tras truncar los logs, estos registros son puro ruido de
  catálogo.

  Conserva siempre: proveedores con credencial (aunque esté inactiva —
  la clave existe y es configuración), modelos con despliegue, y cualquier
  fila `source: \"custom\"` (creación manual deliberada).

  Devuelve `%{models: n, providers: m}` con las filas borradas.
  """
  def purge_unused_catalog do
    # Postgres no soporta left_join en delete_all: se usan subqueries NOT IN
    # (ids acotados — tablas de catálogo, no de uso).
    #
    # Ambos deletes van en UNA transacción: contra un CatalogSync concurrente
    # (lockea models y providers en otro orden) un delete suelto puede
    # deadlockar — y sin transacción el primero quedaba commitado y el segundo
    # no, dejando el catálogo a medias. Con transacción el deadlock se revierte
    # entero y el caller puede reintentar.
    {models_deleted, providers_deleted} =
      Repo.transaction(fn ->
        models =
          Repo.delete_all(
            from(m in Model,
              where:
                m.id not in subquery(
                  from(mp in Tokengate.Providers.ModelProvider, select: mp.model_id)
                )
            )
          )

        providers =
          Repo.delete_all(
            from(p in Provider,
              where:
                p.source != "custom" and
                  p.id not in subquery(
                    from(c in Tokengate.Providers.Credential, select: c.provider_id)
                  )
            )
          )

        {elem(models, 0), elem(providers, 0)}
      end)
      |> case do
        {:ok, counts} -> counts
        {:error, reason} -> raise "purge_unused_catalog failed: #{inspect(reason)}"
      end

    Tokengate.Routing.Cache.invalidate_all()

    %{models: models_deleted, providers: providers_deleted}
  end

  def get_provider!(id), do: Repo.get!(Provider, id)
  def get_provider(id), do: Repo.get(Provider, id)

  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  # Limits live on the provider and the proxy reads them from the cached
  # (model_providers, credential, provider) snapshot, so a limits change must
  # drop that cache or the new throttle would only apply after its 60s TTL.
  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, provider} ->
        Tokengate.Routing.Cache.invalidate_all()
        {:ok, provider}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_provider(%Provider{} = provider) do
    Repo.transaction(fn ->
      # Delete dependent records in order: model_providers → credentials
      # → provider. Each step must succeed before the next.
      credential_ids =
        from(c in Credential, where: c.provider_id == ^provider.id, select: c.id)
        |> Repo.all()

      model_provider_ids =
        if credential_ids != [] do
          from(mp in ModelProvider,
            where: mp.credential_id in ^credential_ids,
            select: mp.id
          )
          |> Repo.all()
        else
          []
        end

      if credential_ids != [] do
        from(mp in ModelProvider, where: mp.credential_id in ^credential_ids)
        |> Repo.delete_all()

        from(c in Credential, where: c.provider_id == ^provider.id)
        |> Repo.delete_all()
      end

      case Repo.delete(provider) do
        {:ok, _} ->
          # Clear sticky routing entries pointing at deleted model providers
          if model_provider_ids != [] do
            Tokengate.Routing.StickyTracker.clear_all_for_provider(model_provider_ids)
          end

          {:ok, provider}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, _} -> {:ok, provider}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def change_provider(%Provider{} = provider, attrs \\ %{}),
    do: Provider.changeset(provider, attrs)

  # ---------------------------------------------------------------------------
  # Provider catalog (models.dev mirror)
  # ---------------------------------------------------------------------------

  @doc """
  Every provider models.dev publishes, ordered by name — the source list for
  the add-provider modal.

  Filtering happens in memory on purpose: the mirror is a few hundred rows and
  the search must feel instant on every keystroke.
  """
  def list_catalog_providers do
    Repo.all(from c in CatalogProvider, order_by: [asc: c.name])
  end

  @doc "Number of mirror rows in the given status (\"active\" | \"stale\")."
  def count_catalog_providers(status) when status in ~w(active stale) do
    Repo.aggregate(from(c in CatalogProvider, where: c.status == ^status), :count)
  end

  @doc "Outcome of the last catalog refresh (nil before the first run)."
  def catalog_sync_state, do: CatalogSyncState.get()

  @doc """
  Enqueues a models.dev catalog refresh. Debounced by the worker's Oban
  uniqueness window, so a double click cannot queue two downloads.
  """
  def request_catalog_refresh do
    %{}
    |> CatalogRefreshWorker.new()
    |> Oban.insert()
  end

  @doc "True when a refresh job is queued or running."
  def catalog_refresh_in_flight?, do: CatalogRefreshWorker.in_flight?()

  # ---------------------------------------------------------------------------
  # Lab catalog (models.dev labs + custom labs)
  # ---------------------------------------------------------------------------

  @doc """
  Every lab, ordered by name.

  Options:

    * `:source` — `"builtin"` | `"custom"`
    * `:status` — `"active"` | `"stale"`
    * `:search` — case-insensitive match on the name or the key

  The catalog is a few dozen rows, so the filters run in the query and the
  result is small enough to hand straight to a view.
  """
  def list_labs(opts \\ []) do
    Lab
    |> order_by([l], asc: l.name)
    |> filter_lab_source(Keyword.get(opts, :source))
    |> filter_lab_status(Keyword.get(opts, :status))
    |> search_labs(Keyword.get(opts, :search))
    |> Repo.all()
  end

  defp filter_lab_source(query, nil), do: query
  defp filter_lab_source(query, source), do: from(l in query, where: l.source == ^source)

  defp filter_lab_status(query, nil), do: query
  defp filter_lab_status(query, status), do: from(l in query, where: l.status == ^status)

  defp search_labs(query, nil), do: query
  defp search_labs(query, ""), do: query

  defp search_labs(query, search) do
    pattern = "%#{search |> String.trim() |> String.downcase()}%"

    from(l in query,
      where: ilike(l.name, ^pattern) or ilike(l.key, ^pattern)
    )
  end

  @doc "A lab by its models.dev key (nil when unknown)."
  def get_lab(key) when is_binary(key), do: Repo.get(Lab, key)
  def get_lab(_), do: nil

  @doc "A lab by its models.dev key, raising when unknown."
  def get_lab!(key), do: Repo.get!(Lab, key)

  @doc "Number of labs in the given status (`\"active\"` | `\"stale\"`)."
  def count_labs(status) when status in ~w(active stale) do
    Repo.aggregate(from(l in Lab, where: l.status == ^status), :count)
  end

  @doc """
  Creates a CUSTOM lab — one models.dev does not publish.

  `source` is forced to `"custom"` here, not taken from the attrs: a row the
  operator creates must never look like a catalog row (a refresh would ignore
  it either way, but the distinction is what the UI keys off). `name` is
  required, `key` is the slug (`"my-lab"`), and `logo_url`/`icon` are the two
  ways to give it a mark — the URL wins when both are set.
  """
  def create_custom_lab(attrs) do
    %Lab{}
    |> Lab.changeset(force_source(attrs, "custom"))
    |> Repo.insert()
  end

  @doc """
  Updates a custom lab. A builtin lab is catalog-owned: it returns a changeset
  carrying a `:builtin` error instead of silently dropping the changes.
  """
  def update_custom_lab(%Lab{source: "custom"} = lab, attrs) do
    lab
    |> Lab.changeset(force_source(attrs, "custom"))
    |> Repo.update()
  end

  def update_custom_lab(%Lab{}, _attrs) do
    {:error,
     %Lab{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:builtin, "it comes from the catalog: it cannot be edited")}
  end

  @doc "Deletes a custom lab (builtin rows: `{:error, :builtin}`)."
  def delete_custom_lab(%Lab{source: "custom"} = lab), do: Repo.delete(lab)
  def delete_custom_lab(%Lab{}), do: {:error, :builtin}

  @doc "Changeset for the custom-lab form."
  def change_lab(%Lab{} = lab, attrs \\ %{}), do: Lab.changeset(lab, attrs)

  # `source` is owned by this context, not by the attrs. Both spellings of the
  # key are cleared, so a form param named "source" cannot slip through beside
  # the forced value.
  defp force_source(attrs, source) do
    attrs
    |> Map.drop(["source", :source])
    |> Map.put("source", source)
  end

  # ---------------------------------------------------------------------------
  # Provider Credentials
  # ---------------------------------------------------------------------------

  @doc "Count of credentials in `error` status (auto-disabled after auth/billing failures)."
  def count_error_credentials do
    Repo.aggregate(from(c in Credential, where: c.status == "error"), :count)
  end

  def list_credentials_for_provider(provider_id) do
    Repo.all(from(c in Credential, where: c.provider_id == ^provider_id))
  end

  def get_credential!(id), do: Repo.get!(Credential, id)
  def get_credential(id), do: Repo.get(Credential, id)

  @doc """
  Returns the first active credential for `provider_id` (status "active",
  ordered by inserted_at ASC). Returns nil when none is active.
  """
  def active_credential(provider_id) do
    Repo.one(
      from(c in Credential,
        where: c.provider_id == ^provider_id and c.status == "active",
        order_by: [asc: c.inserted_at],
        limit: 1
      )
    )
  end

  def create_credential(attrs) do
    %Credential{}
    |> Credential.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, cred} ->
        Tokengate.Routing.Cache.invalidate(:disabled_credentials)
        {:ok, cred}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_credential(%Credential{} = credential, attrs) do
    credential
    |> Credential.update_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, cred} ->
        Tokengate.Routing.Cache.invalidate(:disabled_credentials)
        Tokengate.Routing.Cache.invalidate_all()
        {:ok, cred}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Reactivates a credential that was automatically disabled (status "error")
  after a 401/402/403 from the provider. Clears the error fields and sets the
  status back to "active". Also resets the circuit breaker so the credential
  is immediately eligible for routing.
  """
  def reactivate_credential(%Credential{} = credential) do
    case update_credential(credential, %{
           status: "active",
           error_reason: nil,
           error_message: nil,
           error_at: nil
         }) do
      {:ok, cred} ->
        Tokengate.Routing.CircuitBreakerManager.reset(credential.id)
        {:ok, cred}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_credential(%Credential{} = credential) do
    case Repo.delete(credential) do
      {:ok, cred} ->
        Tokengate.Routing.Cache.invalidate(:disabled_credentials)
        Tokengate.Routing.Cache.invalidate_all()
        {:ok, cred}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def change_credential(%Credential{} = credential, attrs \\ %{}),
    do: Credential.changeset(credential, attrs)

  # ---------------------------------------------------------------------------
  # Model Aliases
  # ---------------------------------------------------------------------------

  def list_models, do: Repo.all(Model)

  def get_model!(id), do: Repo.get!(Model, id)
  def get_model(id), do: Repo.get(Model, id)

  @doc """
  Returns the model model with the given `name`, or nil.
  Alias names are unique.
  """
  def get_model_by_name(name) when is_binary(name) do
    Repo.one(from(ma in Model, where: ma.name == ^name))
  end

  def create_model(attrs) do
    %Model{}
    |> Model.changeset(attrs)
    |> Repo.insert()
  end

  def update_model(%Model{} = model, attrs) do
    model
    |> Model.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, _ma} = ok ->
        Tokengate.Routing.Cache.invalidate_all()
        ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_model(%Model{} = model) do
    # request_logs no longer carries an FK on model_id (dropped in
    # 20260901161239 — the SET NULL made model deletion O(referenced logs)
    # and timed out in production), so there is nothing to declare here:
    # deletion cannot violate referential integrity and log rows keep the
    # model id as historical data.
    model
    |> Repo.delete()
    |> case do
      {:ok, _ma} = ok ->
        Tokengate.Routing.Cache.invalidate_all()
        ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def change_model(%Model{} = model, attrs \\ %{}),
    do: Model.changeset(model, attrs)

  # ---------------------------------------------------------------------------
  # Alias Providers
  # ---------------------------------------------------------------------------

  def list_model_providers, do: Repo.all(ModelProvider)

  def get_model_provider!(id), do: Repo.get!(ModelProvider, id)
  def get_model_provider(id), do: Repo.get(ModelProvider, id)

  @doc """
  Crea varios model_providers en una sola transacción (los targets múltiples
  de un scope exclusivo). Si alguno choca con el índice de exclusividad única
  por (modelo, target) — o con cualquier otra restricción — no se inserta
  ninguno: nunca queda un estado parcial con la mitad de los targets.

  Devuelve `{:ok, count}` o `{:error, changeset}` con el primer error real.
  """
  def create_model_providers_transactional(params_list) when is_list(params_list) do
    result =
      Repo.transaction(fn ->
        Enum.reduce_while(params_list, 0, fn params, acc ->
          case %ModelProvider{}
               |> ModelProvider.changeset(params)
               |> Repo.insert() do
            {:ok, _mp} -> {:cont, acc + 1}
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
      end)

    case result do
      {:ok, count} ->
        Tokengate.Routing.Cache.invalidate_all()
        {:ok, count}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def create_model_provider(attrs) do
    %ModelProvider{}
    |> ModelProvider.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, mp} ->
        Tokengate.Routing.Cache.invalidate_all()
        {:ok, mp}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_model_provider(%ModelProvider{} = model_provider, attrs) do
    model_provider
    |> ModelProvider.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, mp} ->
        Tokengate.Routing.Cache.invalidate_all()
        {:ok, mp}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_model_provider(%ModelProvider{} = model_provider) do
    Repo.transaction(fn ->
      case Repo.delete(model_provider) do
        {:ok, _} ->
          # Clear sticky routing entries pointing at the deleted model provider
          Tokengate.Routing.StickyTracker.clear_all_for_provider([model_provider.id])
          Tokengate.Routing.Cache.invalidate_all()

          {:ok, model_provider}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, model_provider} -> {:ok, model_provider}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def change_model_provider(%ModelProvider{} = model_provider, attrs \\ %{}),
    do: ModelProvider.changeset(model_provider, attrs)

  @doc """
  Returns enabled model_providers for a model, ordered by priority ASC
  with NULLS LAST, preloading credential (with provider).
  Used by the admin UI — shows all providers regardless of scope.
  """
  def list_model_providers(model_id) when is_binary(model_id) do
    from(mp in ModelProvider,
      where: mp.model_id == ^model_id and mp.enabled == true,
      order_by: [asc_nulls_last: mp.priority, asc: mp.credential_id],
      preload: [credential: :provider]
    )
    |> Repo.all()
  end

  @doc """
  Returns ALL model_providers for a model (enabled and disabled),
  preloading credential (with provider). Ordered by priority ASC with
  NULLS LAST.
  """
  def list_all_model_providers(model_id) when is_binary(model_id) do
    from(mp in ModelProvider,
      where: mp.model_id == ^model_id,
      order_by: [asc_nulls_last: mp.priority],
      preload: [credential: :provider]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Exclusive Model Providers — routing queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns model_providers visible to a specific group member for routing.

  Includes:
  - Global providers (no exclusive scope)
  - Providers exclusive to this member
  - Providers exclusive to this member's group

  Returns providers ordered by `exclusive_to_group_member_id` ASC with NULLS
  LAST (member-exclusive rows sort before the NULL `global` rows), then
  priority ASC. The router uses this to inject exclusive
  providers with priority -1.
  """
  def list_model_providers_for_member(model_id, group_member_id, group_id)
      when is_binary(model_id) and is_binary(group_member_id) and is_binary(group_id) do
    model_id
    |> base_query()
    |> scoped_query(group_member_id, group_id)
    |> Repo.all()
  end

  @doc """
  Returns model_providers visible to a **service**: global rows (no exclusive
  scope) plus rows exclusive to that service. Group- and member-exclusive
  rows never apply — services are group-independent.
  """
  def list_model_providers_for_service(model_id, service_id)
      when is_binary(model_id) and is_binary(service_id) do
    model_id
    |> base_query()
    |> where_service_exclusive_only(service_id)
    |> Repo.all()
  end

  defp base_query(model_id) do
    from(mp in ModelProvider,
      where: mp.model_id == ^model_id and mp.enabled == true,
      preload: [credential: :provider]
    )
  end

  defp scoped_query(base, group_member_id, group_id) do
    from(mp in base,
      where:
        (is_nil(mp.exclusive_to_group_member_id) and is_nil(mp.exclusive_to_group_id) and
           is_nil(mp.exclusive_to_service_id)) or
          mp.exclusive_to_group_member_id == ^group_member_id or
          mp.exclusive_to_group_id == ^group_id,
      order_by: [
        asc_nulls_last: mp.exclusive_to_group_member_id,
        asc_nulls_last: mp.priority,
        # Deterministic tiebreaker: rows sharing scope+priority keep a stable
        # order across cache refreshes, so sticky routing (prompt-cache
        # affinity) doesn't flip between equally-prioritized providers.
        asc: mp.credential_id
      ]
    )
  end

  # Service scope: global rows + rows exclusive to this service only. Group-
  # and member-exclusive rows are excluded — services don't inherit them.
  defp where_service_exclusive_only(query, service_id) do
    from(mp in query,
      where:
        (is_nil(mp.exclusive_to_group_member_id) and is_nil(mp.exclusive_to_group_id) and
           is_nil(mp.exclusive_to_service_id)) or
          mp.exclusive_to_service_id == ^service_id,
      order_by: [
        asc_nulls_last: mp.priority,
        # Deterministic tiebreaker: rows sharing scope+priority keep a stable
        # order across cache refreshes, so sticky routing (prompt-cache
        # affinity) doesn't flip between equally-prioritized providers.
        asc: mp.credential_id
      ]
    )
  end

  @doc """
  Checks if a credential is already assigned to any model_provider.
  Returns the model_provider if assigned, nil otherwise.
  """
  def credential_in_use?(credential_id) do
    Repo.one(
      from(mp in ModelProvider,
        where: mp.credential_id == ^credential_id,
        limit: 1
      )
    )
  end

  @doc """
  Returns active credentials available for scope assignment.

  A credential can now serve multiple scope buckets for the same model
  (global + group-exclusive + member-exclusive), so we no longer exclude
  credentials simply because they appear in another model_provider row.

  Filters:
  - Only active credentials
  - Excludes credentials already assigned to the **same scope bucket**
    for this model model (preventing exact-duplicate rows). When editing
    an existing model_provider, the row being edited is excluded from
    the duplicate check.
  """
  def list_available_credentials_for_scope(model_id, scope, opts \\ []) do
    exclude_model_provider_id = Keyword.get(opts, :exclude_model_provider_id)

    # Convert string UUIDs to binaries so fragment EXISTS checks match the
    # binary_id columns without Postgrex encode errors.
    ma_id = dump_uuid!(model_id)
    exclude_id = exclude_model_provider_id && dump_uuid!(exclude_model_provider_id)

    base_query =
      from(c in Credential,
        where: c.status == "active",
        preload: [:provider]
      )

    # Exclude credentials already in the SAME scope bucket for this model,
    # preventing exact-duplicate rows within one bucket. Cross-bucket reuse
    # (global + group-exclusive + member-exclusive) is allowed.
    case scope do
      "member" ->
        if exclude_id do
          from(c in base_query,
            where:
              not fragment(
                "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_id = ? AND mp.exclusive_to_group_member_id IS NOT NULL AND mp.id != ?)",
                c.id,
                ^ma_id,
                ^exclude_id
              )
          )
        else
          from(c in base_query,
            where:
              not fragment(
                "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_id = ? AND mp.exclusive_to_group_member_id IS NOT NULL)",
                c.id,
                ^ma_id
              )
          )
        end

      "group" ->
        if exclude_id do
          from(c in base_query,
            where:
              not fragment(
                "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_id = ? AND mp.exclusive_to_group_id IS NOT NULL AND mp.id != ?)",
                c.id,
                ^ma_id,
                ^exclude_id
              )
          )
        else
          from(c in base_query,
            where:
              not fragment(
                "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_id = ? AND mp.exclusive_to_group_id IS NOT NULL)",
                c.id,
                ^ma_id
              )
          )
        end

      _ ->
        # Global scope
        if exclude_id do
          from(c in base_query,
            where:
              not fragment(
                "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_id = ? AND mp.exclusive_to_group_member_id IS NULL AND mp.exclusive_to_group_id IS NULL AND mp.id != ?)",
                c.id,
                ^ma_id,
                ^exclude_id
              )
          )
        else
          from(c in base_query,
            where:
              not fragment(
                "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_id = ? AND mp.exclusive_to_group_member_id IS NULL AND mp.exclusive_to_group_id IS NULL)",
                c.id,
                ^ma_id
              )
          )
        end
    end
    |> Repo.all()
    |> Enum.sort_by(fn credential ->
      {String.downcase(credential.provider.name), String.downcase(credential.name || "")}
    end)
  end

  # ---------------------------------------------------------------------------
  # Group Member Extra Aliases
  # ---------------------------------------------------------------------------

  def get_group_member_extra_model!(id), do: Repo.get!(GroupMemberExtraModel, id)

  @doc """
  Returns model ids granted as extra models to a specific group member.
  """
  def list_extra_model_ids_for_member(group_member_id) do
    from(tmea in GroupMemberExtraModel,
      where: tmea.group_member_id == ^group_member_id,
      select: tmea.model_id
    )
    |> Repo.all()
  end

  @doc """
  Grants an extra model model to an individual group member (access only, no
  per-model budget). Idempotent: returns `{:error, :already_granted}` if the
  grant already exists.
  """
  def set_extra_model(group_member_id, model_id) do
    grant_extra_model(group_member_id, model_id)
  end

  @doc """
  Grants an extra model model to an individual group member with no budget.
  Idempotent: returns `{:error, :already_granted}` if the grant already exists.
  """
  def grant_extra_model(group_member_id, model_id) do
    %GroupMemberExtraModel{}
    |> GroupMemberExtraModel.changeset(%{
      group_member_id: group_member_id,
      model_id: model_id
    })
    |> Repo.insert()
    |> case do
      {:ok, _tmea} = ok ->
        Tokengate.Routing.Cache.invalidate_accessible_models(nil, group_member_id)
        ok

      other ->
        normalize_unique_error(other)
    end
  end

  @doc """
  Revokes an extra model model from a group member. Idempotent.
  """
  def revoke_extra_model(group_member_id, model_id) do
    case Repo.get_by(GroupMemberExtraModel,
           group_member_id: group_member_id,
           model_id: model_id
         ) do
      nil ->
        {:error, :not_found}

      record ->
        case Repo.delete(record) do
          {:ok, _tmea} = ok ->
            Tokengate.Routing.Cache.invalidate_accessible_models(nil, group_member_id)
            ok

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def change_group_member_extra_model(%GroupMemberExtraModel{} = tmea, attrs \\ %{}),
    do: GroupMemberExtraModel.changeset(tmea, attrs)

  # ---------------------------------------------------------------------------
  # Group Member Denied Models
  # ---------------------------------------------------------------------------

  @doc """
  Returns model ids denied to a specific group member.
  """
  def list_denied_model_ids_for_member(group_member_id) do
    from(tmda in GroupMemberDeniedModel,
      where: tmda.group_member_id == ^group_member_id,
      select: tmda.model_id
    )
    |> Repo.all()
  end

  @doc """
  Revokes a model from an individual group member: adds a deny row for it
  (regardless of whether the access came from the group or from an extra
  grant), so effective access = (group ∪ extras) − denied.

  Idempotent: returns `{:error, :already_denied}` when the deny already
  exists. Invalidates the routing cache for the member.
  """
  def deny_model(group_member_id, model_id) do
    # Un sujeto o un modelo inexistente es `:not_found`, no un changeset con
    # error de FK: el llamador (y la UI) distingue "no existe" de "ya estaba
    # denegado". Se comprueba antes de insertar para no depender del texto del
    # error de Postgres.
    with {:ok, _member} <- fetch_group_member(group_member_id),
         {:ok, _model} <- fetch_model(model_id) do
      %GroupMemberDeniedModel{}
      |> GroupMemberDeniedModel.changeset(%{
        group_member_id: group_member_id,
        model_id: model_id
      })
      |> Repo.insert()
      |> case do
        {:ok, _tmda} = ok ->
          Tokengate.Routing.Cache.invalidate_accessible_models(nil, group_member_id)
          ok

        other ->
          normalize_unique_error(other, :already_denied)
      end
    end
  end

  defp fetch_group_member(id) do
    case Tokengate.Accounts.get_group_member(id) do
      nil -> {:error, :not_found}
      member -> {:ok, member}
    end
  end

  defp fetch_model(id) do
    case Repo.get(Model, id) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @doc """
  Restores a model's access for an individual group member by removing the
  deny row (undeny). Idempotent: returns `{:ok, nil}` when there was nothing
  to remove. Invalidates the routing cache for the member.
  """
  def allow_model(group_member_id, model_id) do
    case Repo.get_by(GroupMemberDeniedModel,
           group_member_id: group_member_id,
           model_id: model_id
         ) do
      nil ->
        {:ok, nil}

      record ->
        case Repo.delete(record) do
          {:ok, tmda} ->
            Tokengate.Routing.Cache.invalidate_accessible_models(nil, group_member_id)
            {:ok, tmda}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def change_group_member_denied_model(%GroupMemberDeniedModel{} = tmda, attrs \\ %{}),
    do: GroupMemberDeniedModel.changeset(tmda, attrs)

  # ---------------------------------------------------------------------------
  # Group Model Aliases
  # ---------------------------------------------------------------------------

  def grant_model_to_group(group_id, model_id) do
    %GroupModel{}
    |> GroupModel.changeset(%{group_id: group_id, model_id: model_id})
    |> Repo.insert()
    |> case do
      {:ok, _tma} = ok ->
        Tokengate.Routing.Cache.invalidate_accessible_models(group_id, nil)
        ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def revoke_model_from_group(group_id, model_id) do
    case Repo.get_by(GroupModel,
           group_id: group_id,
           model_id: model_id
         ) do
      nil ->
        {:ok, nil}

      tma ->
        case Repo.delete(tma) do
          {:ok, _} = ok ->
            Tokengate.Routing.Cache.invalidate_accessible_models(group_id, nil)
            ok

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Service Model Aliases
  # ---------------------------------------------------------------------------

  def grant_model_to_service(service_id, model_id) do
    %ServiceModel{}
    |> ServiceModel.changeset(%{service_id: service_id, model_id: model_id})
    |> Repo.insert()
    |> case do
      {:ok, _sma} = ok ->
        Tokengate.Routing.Cache.invalidate_accessible_models(nil, service_id)
        ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def revoke_model_from_service(service_id, model_id) do
    case Repo.get_by(ServiceModel,
           service_id: service_id,
           model_id: model_id
         ) do
      nil ->
        {:ok, nil}

      sma ->
        case Repo.delete(sma) do
          {:ok, _} = ok ->
            Tokengate.Routing.Cache.invalidate_accessible_models(nil, service_id)
            ok

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Map `%{service_id => [model_id, ...]}` of the models granted to each of the
  given services. One query for the whole set — the read-only supervisor area
  draws badges per service from this instead of one query per card.
  """
  @spec granted_models_by_service([binary()]) :: %{binary() => [binary()]}
  def granted_models_by_service(service_ids) when is_list(service_ids) do
    if service_ids == [] do
      %{}
    else
      Repo.all(
        from sma in ServiceModel,
          where: sma.service_id in ^service_ids,
          select: {sma.service_id, sma.model_id}
      )
      |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, model_id} -> model_id end)
    end
  end

  @doc """
  Models of the catalog for the given ids, ordered by name. Returns `[]` for an
  empty list (no `IN ()` round-trip).
  """
  @spec models_by_ids([binary()]) :: [Model.t()]
  def models_by_ids([]), do: []

  def models_by_ids(model_ids) when is_list(model_ids) do
    Repo.all(from m in Model, where: m.id in ^model_ids, order_by: [asc: m.name])
  end

  # ---------------------------------------------------------------------------
  # Accessible Aliases
  # ---------------------------------------------------------------------------

  @doc """
  Returns the union of models accessible to a group member:
  those granted to their group plus any extra models granted individually.
  A service virtual member (`service_name` set) gets only its own
  service_models — services are group-independent.
  Returns distinct Model structs.
  """
  def list_accessible_models(%{service_name: name} = member) when is_binary(name) do
    # Service (virtual group member) — service_models only.
    service_id = member.id

    alias_ids =
      from(sma in ServiceModel,
        where: sma.service_id == ^service_id,
        select: sma.model_id
      )

    from(ma in Model,
      join: id in subquery(alias_ids),
      on: ma.id == id.model_id
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
  end

  def list_accessible_models(group_member) do
    member_id = group_member.id
    group_id = group_member.group.id

    group_alias_ids =
      from(tma in GroupModel,
        where: tma.group_id == ^group_id,
        select: tma.model_id
      )

    member_alias_ids =
      from(tmea in GroupMemberExtraModel,
        where: tmea.group_member_id == ^member_id,
        select: tmea.model_id
      )

    denied_alias_ids =
      from(tmda in GroupMemberDeniedModel,
        where: tmda.group_member_id == ^member_id,
        select: tmda.model_id
      )

    all_ids =
      group_alias_ids
      |> union(^member_alias_ids)
      |> except(^denied_alias_ids)

    from(ma in Model,
      join: id in subquery(all_ids),
      on: ma.id == id.model_id
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Effective model access for ONE group member:
  `(group grants ∪ individual extras) − individual denies`.

  Returns `{accessible_models, extra_ids, denied_ids}` — the union-minus-
  denied list plus the ids of both individual sets, so callers (LiveView
  picker) can render the 3 states (granted / extra / denied) without extra
  queries.
  """
  @spec list_accessible_models_for_member(map()) :: {[Model.t()], [binary()], [binary()]}
  def list_accessible_models_for_member(%{service_name: name} = member)
      when is_binary(name) do
    # Service (virtual group member) — service_models only; denies are a
    # group-member concept and do not apply.
    service_id = member.id

    alias_ids =
      from(sma in ServiceModel,
        where: sma.service_id == ^service_id,
        select: sma.model_id
      )

    models =
      from(ma in Model,
        join: id in subquery(alias_ids),
        on: ma.id == id.model_id
      )
      |> Repo.all()
      |> Enum.uniq_by(& &1.id)

    {models, [], []}
  end

  def list_accessible_models_for_member(group_member) do
    member_id = group_member.id
    group_id = group_member.group.id

    group_alias_ids =
      from(tma in GroupModel,
        where: tma.group_id == ^group_id,
        select: tma.model_id
      )

    member_alias_ids =
      from(tmea in GroupMemberExtraModel,
        where: tmea.group_member_id == ^member_id,
        select: tmea.model_id
      )

    denied_alias_ids =
      from(tmda in GroupMemberDeniedModel,
        where: tmda.group_member_id == ^member_id,
        select: tmda.model_id
      )

    all_ids =
      group_alias_ids
      |> union(^member_alias_ids)
      |> except(^denied_alias_ids)

    accessible =
      from(ma in Model,
        join: id in subquery(all_ids),
        on: ma.id == id.model_id
      )
      |> Repo.all()
      |> Enum.uniq_by(& &1.id)

    denied_ids =
      from(tmda in GroupMemberDeniedModel,
        where: tmda.group_member_id == ^member_id,
        select: tmda.model_id
      )
      |> Repo.all()

    extra_ids =
      from(tmea in GroupMemberExtraModel,
        where: tmea.group_member_id == ^member_id,
        select: tmea.model_id
      )
      |> Repo.all()

    {accessible, extra_ids, denied_ids}
  end

  @doc """
  Batch variant of `list_accessible_models_for_member/1` for a list of group
  members (e.g. all memberships of one user). Runs a constant number of
  queries regardless of membership count — one for group grants, one for
  individual grants, one for individual denies, one for the models — instead
  of 3N+1.

  Returns `%{member_id => [model, ...]}` with the EFFECTIVE access per member:
  `(their group's grants ∪ their extras) − their denies`. Service virtual
  members get their own service_models (group-independent, no denies).
  """
  def list_accessible_models_for_members(members) when is_list(members) do
    {service_members, real_members} =
      Enum.split_with(members, &is_binary(&1.service_name))

    # Real members carry their group grants; service members are
    # group-independent and only get service_models.
    group_ids =
      real_members
      |> Enum.map(& &1.group.id)
      |> Enum.uniq()

    member_ids = Enum.map(real_members, & &1.id)
    service_ids = Enum.map(service_members, & &1.id)

    group_ids_by_group =
      if group_ids == [] do
        %{}
      else
        Repo.all(
          from tma in GroupModel,
            where: tma.group_id in ^group_ids,
            select: {tma.group_id, tma.model_id}
        )
        |> Enum.group_by(fn {group_id, _} -> group_id end, fn {_, model_id} -> model_id end)
      end

    extra_by_member =
      if member_ids == [] do
        %{}
      else
        Repo.all(
          from tmea in GroupMemberExtraModel,
            where: tmea.group_member_id in ^member_ids,
            select: {tmea.group_member_id, tmea.model_id}
        )
        |> Enum.group_by(fn {member_id, _} -> member_id end, fn {_, model_id} -> model_id end)
      end

    denied_by_member =
      if member_ids == [] do
        %{}
      else
        Repo.all(
          from tmda in GroupMemberDeniedModel,
            where: tmda.group_member_id in ^member_ids,
            select: {tmda.group_member_id, tmda.model_id}
        )
        |> Enum.group_by(fn {member_id, _} -> member_id end, fn {_, model_id} -> model_id end)
      end

    service_ids_by_service =
      if service_ids == [] do
        %{}
      else
        Repo.all(
          from sma in ServiceModel,
            where: sma.service_id in ^service_ids,
            select: {sma.service_id, sma.model_id}
        )
        |> Enum.group_by(fn {service_id, _} -> service_id end, fn {_, model_id} -> model_id end)
      end

    # Effective ids per member = (their group grants ∪ their extras) − their
    # denies. A denied model id without a corresponding grant is a no-op for
    # that member (`--` on a smaller list).
    effective_ids_by_member =
      Map.new(real_members, fn member ->
        granted =
          Enum.uniq(
            Map.get(group_ids_by_group, member.group.id, []) ++
              Map.get(extra_by_member, member.id, [])
          )

        {member.id, granted -- Map.get(denied_by_member, member.id, [])}
      end)

    all_ids =
      effective_ids_by_member
      |> Map.values()
      |> Kernel.++(Map.values(service_ids_by_service))
      |> List.flatten()
      |> Enum.uniq()

    if all_ids == [] do
      %{}
    else
      models_by_id =
        Map.new(Repo.all(from ma in Model, where: ma.id in ^all_ids), fn model ->
          {model.id, model}
        end)

      Map.merge(effective_ids_by_member, service_ids_by_service, fn _id,
                                                                    member_ids,
                                                                    service_ids ->
        Enum.uniq(member_ids ++ service_ids)
      end)
      |> Map.new(fn {member_id, ids} ->
        models =
          ids
          |> Enum.flat_map(fn id ->
            case Map.fetch(models_by_id, id) do
              {:ok, model} -> [model]
              :error -> []
            end
          end)
          |> Enum.sort_by(& &1.name)

        {member_id, models}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_unique_error({:error, %{errors: [unique: _]}}),
    do: {:error, :already_granted}

  defp normalize_unique_error(error), do: error

  # Same as `normalize_unique_error/1` but with a custom reason for the
  # unique-violation case (e.g. `:already_denied` for deny rows).
  # El changeset marca el índice único como `constraint: :unique` (con el
  # nombre del índice), no como `unique: [...]`: se aceptan ambas formas para
  # no depender de cómo Ecto reporte el conflicto.
  defp normalize_unique_error({:error, %Ecto.Changeset{} = cs}, reason) do
    if Enum.any?(cs.errors, fn
         {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
         _ -> false
       end) do
      {:error, reason}
    else
      {:error, cs}
    end
  end

  defp normalize_unique_error(error, _reason), do: error

  # Convert a string UUID to its 16-byte binary representation so it can be
  # used in raw SQL fragments against :binary_id columns.
  defp dump_uuid!(uuid) do
    {:ok, binary} = Ecto.UUID.dump(uuid)
    binary
  end
end
