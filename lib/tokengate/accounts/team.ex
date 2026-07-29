defmodule Tokengate.Accounts.Team do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "teams" do
    field :name, :string
    field :monthly_budget_per_user_usd, :decimal
    field :default_concurrency_limit, :integer, default: 5
    field :default_rpm_limit, :integer, default: 60

    has_many :team_members, Tokengate.Accounts.TeamMember

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(name monthly_budget_per_user_usd
                default_concurrency_limit default_rpm_limit)a
  @required ~w(name)a

  def changeset(team, attrs) do
    team
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_number(:default_concurrency_limit, greater_than: 0)
    |> validate_number(:default_rpm_limit, greater_than: 0)
    |> validate_number(:monthly_budget_per_user_usd, greater_than_or_equal_to: 0)
  end
end
