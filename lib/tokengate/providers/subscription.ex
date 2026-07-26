defmodule Tokengate.Providers.Subscription do
  @moduledoc """
  A subscription plan for a provider (monthly/yearly billing).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @billing_cycles ~w(monthly yearly)
  @statuses ~w(active exhausted cancelled)

  schema "provider_subscriptions" do
    field :name, :string
    field :cost, :decimal
    field :billing_cycle, :string
    field :start_date, :date
    field :end_date, :date
    field :billing_day, :integer
    field :status, :string, default: "active"

    belongs_to :provider, Tokengate.Providers.Provider
    has_many :alias_providers, Tokengate.Providers.AliasProvider

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :provider_id,
      :name,
      :cost,
      :billing_cycle,
      :start_date,
      :end_date,
      :billing_day,
      :status
    ])
    |> validate_required([:provider_id, :name, :cost, :billing_cycle, :start_date, :status])
    |> validate_inclusion(:billing_cycle, @billing_cycles)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:provider_id)
    |> validate_number(:cost, greater_than_or_equal_to: 0)
    |> validate_number(:billing_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
  end

  @doc "List of valid billing_cycle values"
  def billing_cycles, do: @billing_cycles

  @doc "List of valid status values"
  def statuses, do: @statuses
end
