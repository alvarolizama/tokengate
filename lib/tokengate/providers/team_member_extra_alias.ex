defmodule Tokengate.Providers.TeamMemberExtraAlias do
  @moduledoc """
  Join table granting an individual TeamMember extra access to a
  ModelAlias beyond what their team has (M:N).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_member_extra_aliases" do
    # belongs_to TeamMember — module ref resolves at runtime
    belongs_to :team_member, Tokengate.Accounts.TeamMember
    belongs_to :model_alias, Tokengate.Providers.ModelAlias

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(team_member_extra_alias, attrs) do
    team_member_extra_alias
    |> cast(attrs, [:team_member_id, :model_alias_id])
    |> validate_required([:team_member_id, :model_alias_id])
    |> unique_constraint([:team_member_id, :model_alias_id],
      name: :team_member_extra_aliases_team_member_id_model_alias_id_index
    )
    |> foreign_key_constraint(:team_member_id)
    |> foreign_key_constraint(:model_alias_id)
  end
end
