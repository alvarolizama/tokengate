defmodule Tokengate.Repo.Migrations.FixCascadeDeleteForAliasesAndProviders do
  @moduledoc """
  Fixes two FK constraint crashes when deleting model aliases and providers:

  1. Deleting a ModelAlias crashed because `team_model_aliases` and
     `team_member_extra_aliases` had RESTRICT FKs on `model_alias_id`.
     → Change both to ON DELETE CASCADE (join rows die with the alias).

  2. Deleting a Provider crashed because `request_logs.provider_id` (and
     `request_logs.model_alias_id`) had RESTRICT FKs. request_logs is
     append-only (partitioned) — we must never delete history.
     → Change both to ON DELETE SET NULL.

  request_logs is a native Postgres partitioned table, so all FK changes
  on it require raw SQL (drop constraint, re-add with ON DELETE SET NULL).
  """

  use Ecto.Migration

  # --- Join tables: switch to ON DELETE CASCADE -----------------------------

  # team_model_aliases
  defp team_model_alias_fk_name, do: "team_model_aliases_model_alias_id_fkey"

  # team_member_extra_aliases
  defp tmea_fk_name, do: "team_member_extra_aliases_model_alias_id_fkey"

  def up do
    # 1. team_model_aliases — CASCADE on model_alias_id
    execute "ALTER TABLE team_model_aliases DROP CONSTRAINT IF EXISTS #{team_model_alias_fk_name()}",
            "ALTER TABLE team_model_aliases ADD CONSTRAINT #{team_model_alias_fk_name()} FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE RESTRICT"

    execute "ALTER TABLE team_model_aliases ADD CONSTRAINT #{team_model_alias_fk_name()} FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE CASCADE"

    # 2. team_member_extra_aliases — CASCADE on model_alias_id
    execute "ALTER TABLE team_member_extra_aliases DROP CONSTRAINT IF EXISTS #{tmea_fk_name()}",
            "ALTER TABLE team_member_extra_aliases ADD CONSTRAINT #{tmea_fk_name()} FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE RESTRICT"

    execute "ALTER TABLE team_member_extra_aliases ADD CONSTRAINT #{tmea_fk_name()} FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE CASCADE"

    # 3. request_logs — SET NULL on provider_id (append-only, partitioned)
    execute "ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_provider_id_fkey",
            "ALTER TABLE request_logs ADD CONSTRAINT request_logs_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE SET NULL"

    execute "ALTER TABLE request_logs ADD CONSTRAINT request_logs_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE SET NULL"

    # 4. request_logs — SET NULL on model_alias_id (append-only, partitioned)
    execute "ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_model_alias_id_fkey",
            "ALTER TABLE request_logs ADD CONSTRAINT request_logs_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE SET NULL"

    execute "ALTER TABLE request_logs ADD CONSTRAINT request_logs_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE SET NULL"
  end

  def down do
    # Revert request_logs FKs back to RESTRICT (default)
    execute "ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_model_alias_id_fkey"

    execute "ALTER TABLE request_logs ADD CONSTRAINT request_logs_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE SET NULL"

    execute "ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_provider_id_fkey"

    execute "ALTER TABLE request_logs ADD CONSTRAINT request_logs_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES providers(id) ON DELETE SET NULL"

    # Revert join tables back to RESTRICT (default)
    execute "ALTER TABLE team_member_extra_aliases DROP CONSTRAINT IF EXISTS #{tmea_fk_name()}"

    execute "ALTER TABLE team_member_extra_aliases ADD CONSTRAINT #{tmea_fk_name()} FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE RESTRICT"

    execute "ALTER TABLE team_model_aliases DROP CONSTRAINT IF EXISTS #{team_model_alias_fk_name()}"

    execute "ALTER TABLE team_model_aliases ADD CONSTRAINT #{team_model_alias_fk_name()} FOREIGN KEY (model_alias_id) REFERENCES model_aliases(id) ON DELETE RESTRICT"
  end
end
