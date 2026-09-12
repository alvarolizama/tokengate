defmodule Tokengate.Providers.TeamMemberExtraModel do
  @moduledoc """
  Join table granting an individual TeamMember extra access to a
  Model beyond what their team has (M:N).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_member_extra_models" do
    # belongs_to TeamMember — module ref resolves at runtime
    belongs_to :team_member, Tokengate.Accounts.TeamMember
    belongs_to :model, Tokengate.Providers.Model

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(team_member_extra_model, attrs) do
    team_member_extra_model
    |> cast(attrs, [:team_member_id, :model_id])
    |> validate_required([:team_member_id, :model_id])
    |> unique_constraint([:team_member_id, :model_id],
      name: :team_member_extra_models_team_member_id_model_id_index
    )
    |> foreign_key_constraint(:team_member_id)
    |> foreign_key_constraint(:model_id)
  end
end
