defmodule Tokengate.Repo.Migrations.ReplaceCredentialModelAliasUniqueWithPartialIndexes do
  use Ecto.Migration

  @doc """
  Replace the single composite unique index on (credential_id, model_alias_id)
  with three partial unique indexes so the same credential can appear in
  multiple scope rows for the same model alias — global, team-exclusive,
  and member-exclusive — without colliding.

  This allows one API key to serve as an exclusive provider for multiple
  teams / members simultaneously (each at priority -1), while still
  preventing duplicate rows within the same scope bucket.
  """

  def up do
    drop_if_exists unique_index(
                     :model_providers,
                     [:credential_id, :model_alias_id],
                     name: :model_providers_credential_model_alias_unique_index
                   )

    # Global scope — one credential can be global for a model only once.
    create unique_index(
             :model_providers,
             [:credential_id, :model_alias_id],
             name: :model_providers_global_credential_unique_index,
             where: "exclusive_to_team_member_id IS NULL AND exclusive_to_team_id IS NULL"
           )

    # Team-exclusive — one credential per (model, team) pair.
    create unique_index(
             :model_providers,
             [:credential_id, :model_alias_id, :exclusive_to_team_id],
             name: :model_providers_team_exclusive_credential_unique_index,
             where: "exclusive_to_team_id IS NOT NULL"
           )

    # Member-exclusive — one credential per (model, member) pair.
    create unique_index(
             :model_providers,
             [:credential_id, :model_alias_id, :exclusive_to_team_member_id],
             name: :model_providers_member_exclusive_credential_unique_index,
             where: "exclusive_to_team_member_id IS NOT NULL"
           )
  end

  def down do
    drop_if_exists unique_index(
                     :model_providers,
                     [:credential_id, :model_alias_id, :exclusive_to_team_member_id],
                     name: :model_providers_member_exclusive_credential_unique_index
                   )

    drop_if_exists unique_index(
                     :model_providers,
                     [:credential_id, :model_alias_id, :exclusive_to_team_id],
                     name: :model_providers_team_exclusive_credential_unique_index
                   )

    drop_if_exists unique_index(
                     :model_providers,
                     [:credential_id, :model_alias_id],
                     name: :model_providers_global_credential_unique_index
                   )

    create unique_index(
             :model_providers,
             [:credential_id, :model_alias_id],
             name: :model_providers_credential_model_alias_unique_index
           )
  end
end
