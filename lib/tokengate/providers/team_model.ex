defmodule Tokengate.Providers.TeamModel do
  @moduledoc """
  Join table granting a Model to a Team (M:N).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_models" do
    # belongs_to Team — module ref resolves at runtime
    belongs_to :team, Tokengate.Accounts.Team
    belongs_to :model, Tokengate.Providers.Model

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(team_model_model, attrs) do
    team_model_model
    |> cast(attrs, [:team_id, :model_id])
    |> validate_required([:team_id, :model_id])
    |> unique_constraint([:team_id, :model_id],
      name: :team_models_team_id_model_id_index
    )
    |> foreign_key_constraint(:team_id)
    |> foreign_key_constraint(:model_id)
  end
end
