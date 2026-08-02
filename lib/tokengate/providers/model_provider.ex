defmodule Tokengate.Providers.ModelProvider do
  @moduledoc """
  Joins a ModelAlias to a Credential, specifying the actual model name
  at the provider (`provider_model`), priority for routing, and
  enabled flag.

  Each row pins a specific credential — allowing multiple credentials
  from the same provider to serve the same model with different
  priorities for fallback.

  `billing_mode` is the only cost-relevant attribute left: it tells the
  cost calculator whether the upstream is `pay_per_token` (use the
  provider-reported cost from the response body) or `included`
  (subscription/RPM — cost is $0). Per-provider pricing rows are gone;
  we trust the upstream to report what it actually charged.

  ## Exclusive scope

  A model_provider can be scoped to serve only specific consumers:

    * `nil` / `nil` — **global**: available to all team members with access.
    * `exclusive_to_team_member_id` set — **member exclusive**: only the
      specified team member sees this provider for the model.
    * `exclusive_to_team_id` set — **team exclusive**: only members of
      the specified team see this provider for the model.

  The two exclusive fields are mutually exclusive — you cannot set both.
  A credential can be used across different model aliases, but can only
  appear once per model alias (enforced by a composite unique index on
  `credential_id` + `model_alias_id`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @billing_modes ~w(pay_per_token included)
  @scopes ~w(global member team)

  schema "model_providers" do
    field :provider_model, :string
    field :priority, :integer
    field :enabled, :boolean, default: true
    field :billing_mode, :string, default: "pay_per_token"
    field :sticky_ttl_ms, :integer
    field :scope, :string, virtual: true, default: "global"

    belongs_to :model_alias, Tokengate.Providers.ModelAlias
    belongs_to :credential, Tokengate.Providers.Credential
    belongs_to :exclusive_to_team_member, Tokengate.Accounts.TeamMember
    belongs_to :exclusive_to_team, Tokengate.Accounts.Team

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model_provider, attrs) do
    model_provider
    |> cast(attrs, [
      :model_alias_id,
      :credential_id,
      :provider_model,
      :priority,
      :enabled,
      :billing_mode,
      :sticky_ttl_ms,
      :exclusive_to_team_member_id,
      :exclusive_to_team_id
    ])
    |> validate_required([:model_alias_id, :credential_id, :provider_model, :enabled])
    |> validate_inclusion(:billing_mode, @billing_modes)
    |> validate_number(:sticky_ttl_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 24 * 60 * 60 * 1000
    )
    |> validate_exclusive_scope()
    |> foreign_key_constraint(:model_alias_id)
    |> foreign_key_constraint(:credential_id)
    |> foreign_key_constraint(:exclusive_to_team_member_id)
    |> foreign_key_constraint(:exclusive_to_team_id)
    |> unique_constraint(:credential_id,
      name: :model_providers_credential_model_alias_unique_index,
      message: "ya está asignado a este modelo"
    )
    |> sync_scope_field()
  end

  @doc "List of valid billing modes"
  def billing_modes, do: @billing_modes

  @doc "List of valid scopes"
  def scopes, do: @scopes

  # -------------------------------------------------------------------
  # Validations
  # -------------------------------------------------------------------

  defp validate_exclusive_scope(changeset) do
    member_id = get_field(changeset, :exclusive_to_team_member_id)
    team_id = get_field(changeset, :exclusive_to_team_id)

    cond do
      member_id != nil and team_id != nil ->
        add_error(
          changeset,
          :exclusive_to_team_member_id,
          "no se puede asignar a miembro y equipo al mismo tiempo"
        )

      true ->
        changeset
    end
  end

  # Sync the virtual :scope field based on which FK is set, so the form
  # can use a single select to control scope.
  defp sync_scope_field(changeset) do
    member_id = get_field(changeset, :exclusive_to_team_member_id)
    team_id = get_field(changeset, :exclusive_to_team_id)

    scope =
      cond do
        member_id != nil -> "member"
        team_id != nil -> "team"
        true -> "global"
      end

    put_change(changeset, :scope, scope)
  end
end
