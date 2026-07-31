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

  def list_credentials, do: Repo.all(Credential)

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
  end

  def update_credential(%Credential{} = credential, attrs) do
    credential
    |> Credential.update_changeset(attrs)
    |> Repo.update()
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

  def delete_credential(%Credential{} = credential), do: Repo.delete(credential)

  def change_credential(%Credential{} = credential, attrs \\ %{}),
    do: Credential.changeset(credential, attrs)

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
  end

  def update_model_provider(%ModelProvider{} = model_provider, attrs) do
    model_provider
    |> ModelProvider.changeset(attrs)
    |> Repo.update()
  end

  def delete_model_provider(%ModelProvider{} = model_provider) do
    Repo.transaction(fn ->
      case Repo.delete(model_provider) do
        {:ok, _} ->
          # Clear sticky routing entries pointing at the deleted model provider
          Tokengate.Routing.StickyTracker.clear_all_for_provider([model_provider.id])

          {:ok, model_provider}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, _} -> {:ok, model_provider}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def change_model_provider(%ModelProvider{} = model_provider, attrs \\ %{}),
    do: ModelProvider.changeset(model_provider, attrs)

  @doc """
  Returns enabled model_providers for a model_alias, ordered by priority ASC
  with NULLS LAST, preloading credential (with provider).
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
  # Team Member Extra Aliases
  # ---------------------------------------------------------------------------

  def list_team_member_extra_aliases, do: Repo.all(TeamMemberExtraAlias)

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
      on: ma.id == sma.model_alias_id
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_unique_error({:ok, _} = ok), do: ok

  defp normalize_unique_error({:error, %{errors: [unique: _]}}),
    do: {:error, :already_granted}

  defp normalize_unique_error(error), do: error
end
