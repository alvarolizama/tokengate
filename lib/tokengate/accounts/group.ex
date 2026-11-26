defmodule Tokengate.Accounts.Group do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :name, :string
    field :default_concurrency_limit, :integer, default: 5
    field :default_rpm_limit, :integer, default: 60

    # Límite mensual de gasto: nil = sin límite propio, 0 = cero (jamás
    # ilimitado). El único camino a ilimitado es `unlimited_spend`.
    field :monthly_spend_limit_usd, :decimal
    field :unlimited_spend, :boolean, default: false

    # SmartRouter: default del perfil. El miembro lo hereda cuando su propio
    # `router_enabled` es nil (tri-estado), así que apagar el router para un
    # perfil no obliga a editar cada membresía.
    field :router_enabled, :boolean, default: false

    # Baseline de ahorro del perfil (contrafactual que se congela en cada
    # request del router). Es opcional y el modelo puede borrarse: la FK es
    # `ON DELETE NILIFY ALL`, por eso es un uuid crudo y no una asociación
    # (evita que este contexto dependa de `Providers` en compilación).
    field :router_baseline_model_id, :binary_id

    has_many :group_members, Tokengate.Accounts.GroupMember

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name default_concurrency_limit default_rpm_limit monthly_spend_limit_usd unlimited_spend router_enabled router_baseline_model_id)a
  @required ~w(name)a

  def changeset(group, attrs) do
    group
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_number(:default_concurrency_limit, greater_than: 0)
    |> validate_number(:default_rpm_limit, greater_than: 0)
    |> validate_number(:monthly_spend_limit_usd, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:router_baseline_model_id)
  end
end
