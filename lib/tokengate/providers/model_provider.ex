defmodule Tokengate.Providers.ModelProvider do
  @moduledoc """
  Joins a Model to a Credential, specifying the actual model name
  at the provider (`provider_model`), priority for routing, and
  enabled flag.

  Each row pins a specific credential — allowing multiple credentials
  from the same provider to serve the same model with different
  priorities for fallback.

  Billing lives on the provider (`providers.billing_type`, synced from the
  catalog for builtins, chosen at creation for customs). Routing tiers,
  cost calculation and sticky TTL defaults derive it via
  `billing_mode/1`. Per-provider pricing rows are gone; we trust the
  upstream to report what it actually charged.

  ## Exclusive scope

  A model_provider can be scoped to serve only specific consumers:

    * `nil` / `nil` — **global**: available to all group members with access.
    * `exclusive_to_group_member_id` set — **member exclusive**: only the
      specified group member sees this provider for the model.
    * `exclusive_to_group_id` set — **group exclusive**: only members of
      the specified group see this provider for the model.
    * `exclusive_to_service_id` set — **service exclusive**: only the
      specified service sees this provider for the model.

  The exclusive fields are mutually exclusive — you cannot set more than
  one. A credential can be used across different models, and can appear
  in multiple scope rows for the same model model (global, multiple
  group-exclusive, multiple member-exclusive) — each scope bucket has its
  own partial unique index preventing duplicates within that bucket.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @billing_modes ~w(pay_per_token included)
  @scopes ~w(global member group service)

  schema "model_providers" do
    field :provider_model, :string
    field :priority, :integer
    field :enabled, :boolean, default: true
    field :sticky_ttl_ms, :integer
    # Manual pricing fallback (USD per 1M tokens). Used when the upstream
    # doesn't report a cost (e.g. LiteLLM streaming). NULL = not set.
    field :input_cost_per_million, :decimal
    field :output_cost_per_million, :decimal
    field :cache_cost_per_million, :decimal
    # Virtual mirror of `sticky_ttl_ms` in seconds — exposed to the LiveView
    # form so operators can type `900` instead of `900_000`. Synced by
    # `sync_sticky_ttl_fields/1` before saving.
    field :sticky_ttl_seconds, :integer, virtual: true
    # Explicit Anthropic-style cache_control injection on the stable system
    # prefix. Off by default: only upstreams that honor cache_control
    # breakpoints (Anthropic, z.ai's OpenAI-compatible endpoint, OpenRouter
    # passthrough) benefit; elsewhere it's dead payload weight.
    field :cache_control_enabled, :boolean, default: false
    field :scope, :string, virtual: true, default: "global"

    belongs_to :model, Tokengate.Providers.Model
    belongs_to :credential, Tokengate.Providers.Credential
    belongs_to :exclusive_to_group_member, Tokengate.Accounts.GroupMember
    belongs_to :exclusive_to_group, Tokengate.Accounts.Group
    belongs_to :exclusive_to_service, Tokengate.Accounts.Service

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(model_provider, attrs) do
    model_provider
    |> cast(attrs, [
      :model_id,
      :credential_id,
      :provider_model,
      :priority,
      :enabled,
      :sticky_ttl_ms,
      :sticky_ttl_seconds,
      :cache_control_enabled,
      :input_cost_per_million,
      :output_cost_per_million,
      :cache_cost_per_million,
      :exclusive_to_group_member_id,
      :exclusive_to_group_id,
      :exclusive_to_service_id
    ])
    |> validate_required([:model_id, :credential_id, :provider_model, :enabled])
    # 0 is the floor: -1 is reserved at runtime for exclusive providers
    # (Router.inject_exclusive_priority/1), so a configured negative priority
    # on a global row would outrank an exclusive one.
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:sticky_ttl_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 24 * 60 * 60 * 1000
    )
    |> validate_number(:sticky_ttl_seconds,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 24 * 60 * 60
    )
    |> sync_sticky_ttl_fields()
    |> validate_exclusive_scope()
    |> foreign_key_constraint(:model_id)
    |> foreign_key_constraint(:credential_id)
    |> foreign_key_constraint(:exclusive_to_group_member_id)
    |> foreign_key_constraint(:exclusive_to_group_id)
    |> foreign_key_constraint(:exclusive_to_service_id)
    # Three partial unique indexes replace the old single composite index,
    # allowing the same credential to serve multiple scope buckets (global +
    # group-exclusive + member-exclusive) for the same model model.
    |> unique_constraint(:credential_id,
      name: :model_providers_global_credential_unique_index,
      message: "esta credencial ya es global para este modelo"
    )
    |> unique_constraint(:credential_id,
      name: :model_providers_group_exclusive_credential_unique_index,
      message: "esta credencial ya es exclusiva para este grupo y modelo"
    )
    |> unique_constraint(:credential_id,
      name: :model_providers_member_exclusive_credential_unique_index,
      message: "esta credencial ya es exclusiva para este usuario y modelo"
    )
    |> sync_scope_field()
  end

  @doc "List of valid billing modes (derived from the provider surface)"
  def billing_modes, do: @billing_modes

  @doc """
  Effective billing mode for a model_provider, derived from its
  credential's provider: a `subscription` provider maps to `"included"`
  (cost $0, top routing tier); anything else is `"pay_per_token"`.

  Handles not-loaded associations defensively (returns
  `"pay_per_token"`), though production paths always preload
  `credential: :provider`.
  """
  @spec billing_mode(map()) :: String.t()
  def billing_mode(%__MODULE__{} = mp) do
    case mp do
      %__MODULE__{credential: %{provider: %{billing_type: "subscription"}}} -> "included"
      _ -> "pay_per_token"
    end
  end

  @doc "List of valid scopes"
  def scopes, do: @scopes

  # -------------------------------------------------------------------
  # Validations
  # -------------------------------------------------------------------

  defp validate_exclusive_scope(changeset) do
    member_id = get_field(changeset, :exclusive_to_group_member_id)
    group_id = get_field(changeset, :exclusive_to_group_id)
    service_id = get_field(changeset, :exclusive_to_service_id)
    set = Enum.count([member_id, group_id, service_id], &(&1 != nil))

    if set > 1 do
      add_error(
        changeset,
        :exclusive_to_group_member_id,
        "solo se puede asignar un scope exclusivo a la vez"
      )
    else
      changeset
    end
  end

  # Sync the virtual :scope field based on which FK is set, so the form
  # can use a single select to control scope.
  defp sync_scope_field(changeset) do
    member_id = get_field(changeset, :exclusive_to_group_member_id)
    group_id = get_field(changeset, :exclusive_to_group_id)
    service_id = get_field(changeset, :exclusive_to_service_id)

    scope =
      cond do
        member_id != nil -> "member"
        group_id != nil -> "group"
        service_id != nil -> "service"
        true -> "global"
      end

    put_change(changeset, :scope, scope)
  end

  # Keep sticky_ttl_ms (stored) and sticky_ttl_seconds (form) coherent. The
  # form submits seconds; we multiply by 1000 to populate ms. If the user
  # submitted nil for both (no sticky override), we leave nil — StickyTracker
  # then falls back to its 15-min default.
  defp sync_sticky_ttl_fields(changeset) do
    seconds = get_field(changeset, :sticky_ttl_seconds)
    ms = get_field(changeset, :sticky_ttl_ms)

    case {seconds, ms} do
      {nil, ms} when not is_nil(ms) ->
        changeset
        |> put_change(:sticky_ttl_seconds, div(ms, 1000))
        |> force_change(:sticky_ttl_ms, ms)

      {seconds, _} when not is_nil(seconds) ->
        ms_value = seconds * 1000

        changeset
        |> put_change(:sticky_ttl_ms, ms_value)
        |> force_change(:sticky_ttl_seconds, seconds)

      _ ->
        changeset
        |> put_change(:sticky_ttl_ms, nil)
        |> put_change(:sticky_ttl_seconds, nil)
    end
  end
end
