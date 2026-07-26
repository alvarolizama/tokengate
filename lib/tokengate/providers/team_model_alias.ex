defmodule Tokengate.Providers.TeamModelAlias do
  @moduledoc """
  Join table granting a ModelAlias to a Team (M:N).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_model_aliases" do
    # belongs_to Team — module ref resolves at runtime
    belongs_to :team, Tokengate.Accounts.Team
    belongs_to :model_alias, Tokengate.Providers.ModelAlias

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(team_model_alias, attrs) do
    team_model_alias
    |> cast(attrs, [:team_id, :model_alias_id])
    |> validate_required([:team_id, :model_alias_id])
    |> unique_constraint([:team_id, :model_alias_id],
      name: :team_model_aliases_team_id_model_alias_id_index
    )
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:model_alias_id)
  end
end
