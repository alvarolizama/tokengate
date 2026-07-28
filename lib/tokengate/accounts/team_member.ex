defmodule Tokengate.Accounts.TeamMember do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_members" do
    belongs_to :user, Tokengate.Accounts.User
    belongs_to :team, Tokengate.Accounts.Team
    field :team_role, :string, default: "user"
    field :extra_daily_budget_usd, :decimal
    field :extra_concurrency, :integer
    field :extra_rpm, :integer
    field :status, :string, default: "active"

    has_one :api_key, Tokengate.Accounts.ApiKey

    timestamps(type: :utc_datetime)
  end

  @permitted ~w(user_id team_id team_role extra_daily_budget_usd
                extra_concurrency extra_rpm status)a
  @required ~w(user_id team_id)a

  def changeset(team_member, attrs) do
    team_member
    |> cast(attrs, @permitted)
    |> validate_required(@required)
    |> validate_inclusion(:team_role, ["manager", "user"])
    |> validate_inclusion(:status, ["active", "suspended"])
    |> validate_number(:extra_daily_budget_usd, greater_than_or_equal_to: 0)
    |> validate_number(:extra_concurrency, greater_than: 0)
    |> validate_number(:extra_rpm, greater_than: 0)
    |> unique_constraint(:team_id, name: :team_members_user_team_unique_index)
    |> assoc_constraint(:user)
    |> assoc_constraint(:team)
  end
end
