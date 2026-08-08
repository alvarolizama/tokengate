defmodule Tokengate.Providers do
  @moduledoc """
  The Providers context.

  Manages the routing domain: providers, credentials, model aliases, alias
  providers, and team/member alias grants.

  ## Cost model (since 2026-07-30)

  Per-provider pricing rows (`model_pricing`) and per-alias market prices
  have been removed. `provider_cost_usd` is whatever the upstream reports
  in its response body (`usage.cost` for OpenAI-compatible gateways). The
  only cost-relevant attribute remaining is `model_providers.billing_mode`:
  `"pay_per_token"` (use upstream-reported cost when available) or
  `"included"` (subscription / RPM-limited — cost is $0).

  All `belongs_to` references to `Tokengate.Accounts.*` modules resolve at
  runtime — the Accounts context may not be compiled when this module is.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Repo

  alias Tokengate.Providers.{
    Provider,
    Credential,
    ModelAlias,
    ModelProvider,
    ServiceModelAlias,
    TeamModelAlias,
    TeamMemberExtraAlias
  }

  # ---------------------------------------------------------------------------
  # Providers
  # ---------------------------------------------------------------------------

  def list_providers, do: Repo.all(Provider)

  def get_provider!(id), do: Repo.get!(Provider, id)
  def get_provider(id), do: Repo.get(Provider, id)

  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
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

  def list_model_aliases, do: Repo.all(ModelAlias)

  def get_model_alias!(id), do: Repo.get!(ModelAlias, id)
  def get_model_alias(id), do: Repo.get(ModelAlias, id)

  @doc """
  Returns the model alias with the given `name`, or nil.
  Alias names are unique.
  """
  def get_alias_by_name(name) when is_binary(name) do
    Repo.one(from(ma in ModelAlias, where: ma.name == ^name))
  end

  def create_model_alias(attrs) do
    %ModelAlias{}
    |> ModelAlias.changeset(attrs)
    |> Repo.insert()
  end

  def update_model_alias(%ModelAlias{} = model_alias, attrs) do
    model_alias
    |> ModelAlias.changeset(attrs)
    |> Repo.update()
  end

  def delete_model_alias(%ModelAlias{} = model_alias) do
    model_alias
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:model_alias_id,
      name: "request_logs_model_alias_id_fkey",
      message: "el modelo tiene logs de uso y no se puede eliminar"
    )
    |> Repo.delete()
  end

  def change_model_alias(%ModelAlias{} = model_alias, attrs \\ %{}),
    do: ModelAlias.changeset(model_alias, attrs)

  # ---------------------------------------------------------------------------
  # Alias Providers
  # ---------------------------------------------------------------------------

  def list_model_providers, do: Repo.all(ModelProvider)

  def get_model_provider!(id), do: Repo.get!(ModelProvider, id)
  def get_model_provider(id), do: Repo.get(ModelProvider, id)

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
  Returns enabled model_providers for a model_alias (global only),
  ordered by priority ASC with NULLS LAST, preloading credential (with provider).
  Used by the admin UI — shows all providers regardless of scope.
  """
  def list_model_providers(model_alias_id) when is_binary(model_alias_id) do
    from(mp in ModelProvider,
      where: mp.model_alias_id == ^model_alias_id and mp.enabled == true,
      order_by: [asc_nulls_last: mp.priority],
      preload: [credential: :provider]
    )
    |> Repo.all()
  end

  @doc """
  Returns ALL model_providers for a model_alias (enabled and disabled),
  preloading credential (with provider). Ordered by priority ASC with
  NULLS LAST.
  """
  def list_all_model_providers(model_alias_id) when is_binary(model_alias_id) do
    from(mp in ModelProvider,
      where: mp.model_alias_id == ^model_alias_id,
      order_by: [asc_nulls_last: mp.priority],
      preload: [credential: :provider]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Exclusive Model Providers — routing queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns model_providers visible to a specific team member for routing.

  Includes:
  - Global providers (no exclusive scope)
  - Providers exclusive to this member
  - Providers exclusive to this member's team

  Returns providers ordered by: exclusive_to_team_member_id DESC (member
  first), then priority ASC. The router uses this to inject exclusive
  providers with priority -1.
  """
  def list_model_providers_for_member(model_alias_id, team_member_id, team_id)
      when is_binary(model_alias_id) and is_binary(team_member_id) and is_binary(team_id) do
    # Build base query: enabled providers for this model alias
    base_query =
      from(mp in ModelProvider,
        where: mp.model_alias_id == ^model_alias_id and mp.enabled == true,
        preload: [credential: :provider]
      )

    # Add scope filter: global OR exclusive to this member OR exclusive to this team.
    # NOTE: "global" means BOTH exclusive fields are nil. Checking only
    # exclusive_to_team_member_id leaks team-exclusive providers to every
    # other team (they have exclusive_to_team_id set, member id nil).
    query =
      from(mp in base_query,
        where:
          (is_nil(mp.exclusive_to_team_member_id) and is_nil(mp.exclusive_to_team_id)) or
            mp.exclusive_to_team_member_id == ^team_member_id or
            mp.exclusive_to_team_id == ^team_id,
        order_by: [
          asc_nulls_last: mp.exclusive_to_team_member_id,
          asc_nulls_last: mp.priority
        ]
      )

    Repo.all(query)
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

  Filters:
  - Only active credentials
  - Excludes credentials already in use by other model_providers (unless
    the model_provider is the one being edited, passed as exclude_id)
  - When scope is "member": excludes credentials already exclusive to
    another member for the same model_alias
  - When scope is "team": excludes credentials already exclusive to
    another team for the same model_alias
  """
  def list_available_credentials_for_scope(model_alias_id, scope, opts \\ []) do
    exclude_model_provider_id = Keyword.get(opts, :exclude_model_provider_id)

    base_query =
      from(c in Credential,
        where: c.status == "active",
        preload: [:provider]
      )

    # Exclude credentials already used by other model_providers
    base_query =
      if exclude_model_provider_id do
        from(c in base_query,
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.id != ?)",
              c.id,
              ^exclude_model_provider_id
            )
        )
      else
        from(c in base_query,
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ?)",
              c.id
            )
        )
      end

    # Additional scope-specific exclusions
    case scope do
      "member" ->
        # Exclude credentials already exclusive to another member for this model
        from(c in base_query,
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_alias_id = ? AND mp.exclusive_to_team_member_id IS NOT NULL)",
              c.id,
              ^model_alias_id
            )
        )

      "team" ->
        # Exclude credentials already exclusive to another team for this model
        from(c in base_query,
          where:
            not fragment(
              "EXISTS (SELECT 1 FROM model_providers mp WHERE mp.credential_id = ? AND mp.model_alias_id = ? AND mp.exclusive_to_team_id IS NOT NULL)",
              c.id,
              ^model_alias_id
            )
        )

      _ ->
        base_query
    end
    |> Repo.all()
    |> Enum.sort_by(fn credential ->
      {String.downcase(credential.provider.name), String.downcase(credential.name || "")}
    end)
  end

  # ---------------------------------------------------------------------------
  # Team Member Extra Aliases
  # ---------------------------------------------------------------------------

  def get_team_member_extra_alias!(id), do: Repo.get!(TeamMemberExtraAlias, id)

  @doc """
  Returns model_alias ids granted as extra aliases to a specific team member.
  """
  def list_extra_alias_ids_for_member(team_member_id) do
    from(tmea in TeamMemberExtraAlias,
      where: tmea.team_member_id == ^team_member_id,
      select: tmea.model_alias_id
    )
    |> Repo.all()
  end

  @doc """
  Grants an extra model alias to an individual team member (access only, no
  per-model budget). Idempotent: returns `{:error, :already_granted}` if the
  grant already exists.
  """
  def set_extra_alias(team_member_id, model_alias_id) do
    grant_extra_alias(team_member_id, model_alias_id)
  end

  @doc """
  Grants an extra model alias to an individual team member with no budget.
  Idempotent: returns `{:error, :already_granted}` if the grant already exists.
  """
  def grant_extra_alias(team_member_id, model_alias_id) do
    %TeamMemberExtraAlias{}
    |> TeamMemberExtraAlias.changeset(%{
      team_member_id: team_member_id,
      model_alias_id: model_alias_id
    })
    |> Repo.insert()
    |> normalize_unique_error()
  end

  @doc """
  Revokes an extra model alias from a team member. Idempotent.
  """
  def revoke_extra_alias(team_member_id, model_alias_id) do
    case Repo.get_by(TeamMemberExtraAlias,
           team_member_id: team_member_id,
           model_alias_id: model_alias_id
         ) do
      nil -> {:error, :not_found}
      record -> Repo.delete(record)
    end
  end

  def change_team_member_extra_alias(%TeamMemberExtraAlias{} = tmea, attrs \\ %{}),
    do: TeamMemberExtraAlias.changeset(tmea, attrs)

  # ---------------------------------------------------------------------------
  # Team Model Aliases
  # ---------------------------------------------------------------------------

  def grant_alias_to_team(team_id, model_alias_id) do
    %TeamModelAlias{}
    |> TeamModelAlias.changeset(%{team_id: team_id, model_alias_id: model_alias_id})
    |> Repo.insert()
  end

  def revoke_alias_from_team(team_id, model_alias_id) do
    case Repo.get_by(TeamModelAlias,
           team_id: team_id,
           model_alias_id: model_alias_id
         ) do
      nil -> {:ok, nil}
      tma -> Repo.delete(tma)
    end
  end

  # ---------------------------------------------------------------------------
  # Service Model Aliases
  # ---------------------------------------------------------------------------

  def grant_alias_to_service(service_id, model_alias_id) do
    %ServiceModelAlias{}
    |> ServiceModelAlias.changeset(%{service_id: service_id, model_alias_id: model_alias_id})
    |> Repo.insert()
  end

  def revoke_alias_from_service(service_id, model_alias_id) do
    case Repo.get_by(ServiceModelAlias,
           service_id: service_id,
           model_alias_id: model_alias_id
         ) do
      nil -> {:ok, nil}
      sma -> Repo.delete(sma)
    end
  end

  # ---------------------------------------------------------------------------
  # Accessible Aliases
  # ---------------------------------------------------------------------------

  @doc """
  Returns the union of model aliases accessible to a team member:
  those granted to their team plus any extra aliases granted individually.
  Returns distinct ModelAlias structs.

  Expects a team_member struct with `:id` and `:team` preloaded (team must have `:id`).
  """
  def list_accessible_aliases(%{team: nil} = member) do
    # Service (virtual team member) — only service_model_aliases
    service_id = member.id

    from(sma in ServiceModelAlias,
      where: sma.service_id == ^service_id,
      join: ma in ModelAlias,
      on: ma.id == sma.model_alias_id,
      select: ma
    )
    |> Repo.all()
  end

  def list_accessible_aliases(team_member) do
    member_id = team_member.id
    team_id = team_member.team.id

    team_alias_ids =
      from(tma in TeamModelAlias,
        where: tma.team_id == ^team_id,
        select: tma.model_alias_id
      )

    member_alias_ids =
      from(tmea in TeamMemberExtraAlias,
        where: tmea.team_member_id == ^member_id,
        select: tmea.model_alias_id
      )

    all_ids = team_alias_ids |> union(^member_alias_ids)

    from(ma in ModelAlias,
      join: id in subquery(all_ids),
      on: ma.id == id.model_alias_id
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Batch variant of `list_accessible_aliases/1` for a list of team members
  (e.g. all memberships of one user). Runs a constant number of queries
  regardless of membership count — one for team grants, one for individual
  grants, one for the aliases — instead of 2N+1.
  """
  def list_accessible_aliases_for_members(members) when is_list(members) do
    {service_ids, real_members} = Enum.split_with(members, &(&1.team == nil))

    team_ids = real_members |> Enum.map(& &1.team.id) |> Enum.uniq()
    member_ids = Enum.map(real_members, & &1.id)

    team_alias_ids =
      if team_ids == [] do
        []
      else
        Repo.all(
          from tma in TeamModelAlias,
            where: tma.team_id in ^team_ids,
            select: tma.model_alias_id
        )
      end

    member_alias_ids =
      if member_ids == [] do
        []
      else
        Repo.all(
          from tmea in TeamMemberExtraAlias,
            where: tmea.team_member_id in ^member_ids,
            select: tmea.model_alias_id
        )
      end

    service_alias_ids =
      if service_ids == [] do
        []
      else
        Repo.all(
          from sma in ServiceModelAlias,
            where: sma.service_id in ^service_ids,
            select: sma.model_alias_id
        )
      end

    all_ids = Enum.uniq(team_alias_ids ++ member_alias_ids ++ service_alias_ids)

    if all_ids == [] do
      []
    else
      Repo.all(from ma in ModelAlias, where: ma.id in ^all_ids)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_unique_error({:ok, _} = ok), do: ok

  defp normalize_unique_error({:error, %{errors: [unique: _]}}),
    do: {:error, :already_granted}

  defp normalize_unique_error(error), do: error
end
