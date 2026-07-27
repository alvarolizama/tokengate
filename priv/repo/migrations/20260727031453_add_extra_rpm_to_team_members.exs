defmodule Tokengate.Repo.Migrations.AddExtraRpmToTeamMembers do
  use Ecto.Migration

  def change do
    alter table(:team_members) do
      add :extra_rpm, :integer
    end
  end
end
