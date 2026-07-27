defmodule Tokengate.Providers do
  @moduledoc """
  The Providers context.

  Manages the routing domain: providers, credentials,
  model aliases, alias providers, pricing, routing rules, and team/member
  alias grants.

  All `belongs_to` references to `Tokengate.Accounts.*` modules resolve at
  runtime — the Accounts context may not be compiled when this module is.
  """

  import Ecto.Query, warn: false
  alias Tokengate.Repo

  alias Tokengate.Providers.{
    Provider,
    Credential,
    ModelAlias,
    AliasProvider,
    ModelPricing,
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

  def delete_provider(%Provider{} = provider), do: Repo.delete(provider)

  def change_provider(%Provider{} = provider, attrs \\ %{}),
    do: Provider.changeset(provider, attrs)

  # ---------------------------------------------------------------------------
  # Provider Credentials
  # ---------------------------------------------------------------------------

  def list_credentials, do: Repo.all(Credential)

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
    |> Credential.changeset(attrs)
    |> Repo.update()
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

  def delete_model_alias(%ModelAlias{} = model_alias), do: Repo.delete(model_alias)

  def change_model_alias(%ModelAlias{} = model_alias, attrs \\ %{}),
    do: ModelAlias.changeset(model_alias, attrs)

  # ---------------------------------------------------------------------------
  # Alias Providers
  # ---------------------------------------------------------------------------

  def list_alias_providers, do: Repo.all(AliasProvider)

  def get_alias_provider!(id), do: Repo.get!(AliasProvider, id)
  def get_alias_provider(id), do: Repo.get(AliasProvider, id)

  def create_alias_provider(attrs) do
    %AliasProvider{}
    |> AliasProvider.changeset(attrs)
    |> Repo.insert()
  end

  def update_alias_provider(%AliasProvider{} = alias_provider, attrs) do
    alias_provider
    |> AliasProvider.changeset(attrs)
    |> Repo.update()
  end

  def delete_alias_provider(%AliasProvider{} = alias_provider), do: Repo.delete(alias_provider)

  def change_alias_provider(%AliasProvider{} = alias_provider, attrs \\ %{}),
    do: AliasProvider.changeset(alias_provider, attrs)

  @doc """
  Returns enabled alias_providers for a model_alias, ordered by priority ASC
  with NULLS LAST, preloading provider, and model_pricing.
  """
  def list_alias_providers(model_alias_id) when is_binary(model_alias_id) do
    from(ap in AliasProvider,
      where: ap.model_alias_id == ^model_alias_id and ap.enabled == true,
      order_by: [asc_nulls_last: ap.priority],
      preload: [:provider, :model_pricing]
    )
    |> Repo.all()
  end

  @doc """
  Returns ALL alias_providers for a model_alias (enabled and disabled),
  preloading provider and model_pricing. Ordered by priority
  ASC with NULLS LAST, then by provider name.
  """
  def list_all_alias_providers(model_alias_id) when is_binary(model_alias_id) do
    from(ap in AliasProvider,
      where: ap.model_alias_id == ^model_alias_id,
      order_by: [asc_nulls_last: ap.priority],
      preload: [:provider, :model_pricing]
    )
    |> Repo.all()
  end

  @doc """
  Returns all alias_providers, preloading provider, model_alias, and
  model_pricing. Used by the pricing admin.
  """
  def list_pay_per_token_alias_providers do
    from(ap in AliasProvider,
      join: p in assoc(ap, :provider),
      preload: [provider: p, model_alias: [], model_pricing: :alias_provider],
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  Returns all alias_providers for a model_alias with provider and model_pricing
  preloaded, including the model_alias association. Used by the pricing admin
  when filtering by alias.
  """
  def list_alias_providers_for_pricing(model_alias_id) when is_binary(model_alias_id) do
    from(ap in AliasProvider,
      join: p in assoc(ap, :provider),
      where: ap.model_alias_id == ^model_alias_id,
      preload: [provider: p, model_pricing: :alias_provider],
      order_by: [asc_nulls_last: ap.priority]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Model Pricing
  # ---------------------------------------------------------------------------

  def list_model_pricing, do: Repo.all(ModelPricing)

  def get_model_pricing!(id), do: Repo.get!(ModelPricing, id)
  def get_model_pricing(id), do: Repo.get(ModelPricing, id)

  def create_model_pricing(attrs) do
    %ModelPricing{}
    |> ModelPricing.changeset(attrs)
    |> Repo.insert()
  end

  def update_model_pricing(%ModelPricing{} = model_pricing, attrs) do
    model_pricing
    |> ModelPricing.changeset(attrs)
    |> Repo.update()
  end

  def delete_model_pricing(%ModelPricing{} = model_pricing), do: Repo.delete(model_pricing)

  def change_model_pricing(%ModelPricing{} = model_pricing, attrs \\ %{}),
    do: ModelPricing.changeset(model_pricing, attrs)

  @doc """
  Returns the latest ModelPricing for an alias_provider by effective_from.
  """
  def current_pricing(alias_provider_id) do
    from(p in ModelPricing,
      where: p.alias_provider_id == ^alias_provider_id,
      order_by: [desc: p.effective_from],
      limit: 1
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
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
  Grants an extra model alias to an individual team member. Idempotent:
  returns `{:error, :already_granted}` if the grant already exists.
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
  # Accessible Aliases
  # ---------------------------------------------------------------------------

  @doc """
  Returns the union of model aliases accessible to a team member:
  those granted to their team plus any extra aliases granted individually.
  Returns distinct ModelAlias structs.

  Expects a team_member struct with `:id` and `:team` preloaded (team must have `:id`).
  """
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
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_unique_error({:ok, record}), do: {:ok, record}

  defp normalize_unique_error({:error, changeset}) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)

    has_unique? =
      Enum.any?(errors, fn {_field, messages} ->
        Enum.any?(List.wrap(messages), &String.contains?(&1, "already"))
      end)

    if has_unique?, do: {:error, :already_granted}, else: {:error, changeset}
  end
end
