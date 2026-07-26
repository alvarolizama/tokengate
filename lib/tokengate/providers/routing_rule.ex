defmodule Tokengate.Providers.RoutingRule do
  @moduledoc """
  Organization-scoped routing rules that map request conditions
  (e.g. context length, image presence) to a target model alias.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "routing_rules" do
    field :name, :string
    field :conditions, :map, default: %{}
    field :priority, :integer, default: 1
    field :enabled, :boolean, default: true

    # belongs_to Organization — module ref resolves at runtime
    belongs_to :organization, Tokengate.Accounts.Organization
    belongs_to :target_alias, Tokengate.Providers.ModelAlias

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(routing_rule, attrs) do
    routing_rule
    |> cast(attrs, [:organization_id, :name, :conditions, :target_alias_id, :priority, :enabled])
    |> validate_required([:organization_id, :name, :conditions, :target_alias_id])
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:target_alias_id)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
  end
end
