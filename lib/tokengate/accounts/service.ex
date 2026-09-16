defmodule Tokengate.Accounts.Service do
  @moduledoc """
  Servicio — consumidor machine de la API, independiente de grupos.

  Sin sub (`subscription_id == nil`) el consumo es ilimitado en crédito
  (tier 3, solo aplica el cap global diario). Con sub, cada service es un
  grant propio: dos services que apunten a la misma sub drenan bolsines
  separados. `concurrency_limit`/`rpm_limit` son absolutos (no extras).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @default_concurrency 5
  @default_rpm 60

  schema "services" do
    field :name, :string
    # Límites absolutos (nil → default del módulo).
    field :concurrency_limit, :integer
    field :rpm_limit, :integer

    # Límite mensual de gasto: nil = sin límite propio, 0 = cero (jamás
    # ilimitado). El único camino a ilimitado es `unlimited_spend`.
    field :monthly_spend_limit_usd, :decimal
    field :unlimited_spend, :boolean, default: false

    # Sub de crédito directa (opcional; nil = ilimitado, tier 3).
    belongs_to :subscription, Tokengate.Credits.Subscription

    has_one :api_key, Tokengate.Accounts.ApiKey
    has_many :models, Tokengate.Providers.ServiceModel
    has_many :supervisors, Tokengate.Accounts.ServiceSupervisor
    has_many :supervisor_users, through: [:supervisors, :user]

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name subscription_id concurrency_limit rpm_limit monthly_spend_limit_usd unlimited_spend)a
  @required ~w(name)a

  def changeset(service, attrs) do
    service
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_number(:concurrency_limit, greater_than: 0)
    |> validate_number(:rpm_limit, greater_than: 0)
    |> validate_number(:monthly_spend_limit_usd, greater_than_or_equal_to: 0)
    |> assoc_constraint(:subscription)
  end

  @doc "Defaults de límites cuando el service no define los suyos."
  def default_limits, do: %{concurrency_limit: @default_concurrency, rpm_limit: @default_rpm}
end
