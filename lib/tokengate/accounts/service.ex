defmodule Tokengate.Accounts.Service do
  @moduledoc """
  Servicio — consumidor machine de la API. Miembro obligatorio de un
  grupo: hereda defaults del grupo (presupuesto, concurrencia, RPM) y
  sus propios campos actúan como extras aditivos sobre esos defaults.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "services" do
    field :name, :string
    # Extras aditivos sobre los defaults del grupo.
    field :monthly_budget_usd, :decimal
    field :concurrency_limit, :integer
    field :rpm_limit, :integer

    belongs_to :group, Tokengate.Accounts.Group
    has_one :api_key, Tokengate.Accounts.ApiKey
    has_many :models, Tokengate.Providers.ServiceModel
    has_many :supervisors, Tokengate.Accounts.ServiceSupervisor
    has_many :supervisor_users, through: [:supervisors, :user]

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name group_id monthly_budget_usd concurrency_limit rpm_limit)a
  @required ~w(name group_id)a

  def changeset(service, attrs) do
    service
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_number(:concurrency_limit, greater_than: 0)
    |> validate_number(:rpm_limit, greater_than: 0)
    |> validate_number(:monthly_budget_usd, greater_than_or_equal_to: 0)
    |> assoc_constraint(:group)
  end
end
