defmodule Tokengate.Repo.Migrations.AddExclusiveScopeToModelProviders do
  use Ecto.Migration

  def up do
    alter table(:model_providers) do
      add :exclusive_to_team_member_id,
          references(:team_members, type: :binary_id, on_delete: :delete_all)

      add :exclusive_to_team_id, references(:teams, type: :binary_id, on_delete: :delete_all)
    end

    create unique_index(:model_providers, [:credential_id],
             name: :model_providers_credential_id_unique_index
           )
  end

  def down do
    drop_if_exists unique_index(:model_providers, :credential_id,
                     name: :model_providers_credential_id_unique_index
                   )

    alter table(:model_providers) do
      remove :exclusive_to_team_member_id
      remove :exclusive_to_team_id
    end
  end
end
