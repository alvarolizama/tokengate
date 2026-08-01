defmodule Tokengate.Accounts.Service do
  @moduledoc """
  Schema for services — API keys not tied to a user.
  Services have direct limits (no team hierarchy).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "services" do
    field :name, :string
    field :monthly_budget_usd, :decimal
    field :concurrency_limit, :integer, default: 5
    field :rpm_limit, :integer, default: 60

    has_one :api_key, Tokengate.Accounts.ServiceApiKey
    has_many :model_aliases, Tokengate.Providers.ServiceModelAlias
    has_many :supervisors, Tokengate.Accounts.ServiceSupervisor
    has_many :supervisor_users, through: [:supervisors, :user]

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name monthly_budget_usd concurrency_limit rpm_limit)a
  @required ~w(name)a

  def changeset(service, attrs) do
    service
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_number(:concurrency_limit, greater_than: 0)
    |> validate_number(:rpm_limit, greater_than: 0)
    |> validate_number(:monthly_budget_usd, greater_than_or_equal_to: 0)
  end
end
