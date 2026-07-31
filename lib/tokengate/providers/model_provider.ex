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
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @billing_modes ~w(pay_per_token included)

  schema "model_providers" do
    field :provider_model, :string
    field :priority, :integer
    field :enabled, :boolean, default: true
    field :billing_mode, :string, default: "pay_per_token"
    field :context_window, :integer

    belongs_to :model_alias, Tokengate.Providers.ModelAlias
    belongs_to :credential, Tokengate.Providers.Credential

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
      :context_window
    ])
    |> validate_required([:model_alias_id, :credential_id, :provider_model, :enabled])
    |> validate_inclusion(:billing_mode, @billing_modes)
    |> foreign_key_constraint(:model_alias_id)
    |> foreign_key_constraint(:credential_id)
  end

  @doc "List of valid billing modes"
  def billing_modes, do: @billing_modes
end
