defmodule Tokengate.Repo.Migrations.CascadeDeleteUser do
  @moduledoc """
  Enables cascade-delete of a user and all their associated data:

  1. team_members.user_id        → ON DELETE CASCADE
  2. api_keys.team_member_id     → ON DELETE CASCADE
  3. request_logs.team_member_id → ON DELETE CASCADE (partitioned, raw SQL)
  4. audit_logs.user_id          → ON DELETE SET NULL (keep audit trail)

  When a user is deleted:
  - Their team_members are deleted (CASCADE from users)
  - Their api_keys are deleted (CASCADE from team_members)
  - Their request_logs are deleted (CASCADE from team_members)
  - Their audit_log entries are kept but user_id is nilified (SET NULL)

  WARNING: Deleting a user erases ALL their consumption history (request_logs).
  This is intentional — the admin is warned via a confirmation modal.
  """

  use Ecto.Migration

  def up do
    # 1. team_members — CASCADE on user_id
    execute "ALTER TABLE team_members DROP CONSTRAINT IF EXISTS team_members_user_id_fkey",
            "ALTER TABLE team_members ADD CONSTRAINT team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT"

    execute "ALTER TABLE team_members ADD CONSTRAINT team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"

    # 2. api_keys — CASCADE on team_member_id
    execute "ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_team_member_id_fkey",
            "ALTER TABLE api_keys ADD CONSTRAINT api_keys_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES team_members(id) ON DELETE RESTRICT"

    execute "ALTER TABLE api_keys ADD CONSTRAINT api_keys_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES team_members(id) ON DELETE CASCADE"

    # 3. request_logs — CASCADE on team_member_id (partitioned, raw SQL)
    execute "ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_team_member_id_fkey",
            "ALTER TABLE request_logs ADD CONSTRAINT request_logs_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES team_members(id) ON DELETE RESTRICT"

    execute "ALTER TABLE request_logs ADD CONSTRAINT request_logs_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES team_members(id) ON DELETE CASCADE"

    # 4. audit_logs — SET NULL on user_id (keep audit trail, lose attribution)
    execute "ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_user_id_fkey",
            "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL"

    execute "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL"
  end

  def down do
    # Revert all FKs back to RESTRICT (default)
    execute "ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_user_id_fkey"

    execute "ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL"

    execute "ALTER TABLE request_logs DROP CONSTRAINT IF EXISTS request_logs_team_member_id_fkey"

    execute "ALTER TABLE request_logs ADD CONSTRAINT request_logs_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES team_members(id) ON DELETE RESTRICT"

    execute "ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_team_member_id_fkey"

    execute "ALTER TABLE api_keys ADD CONSTRAINT api_keys_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES team_members(id) ON DELETE RESTRICT"

    execute "ALTER TABLE team_members DROP CONSTRAINT IF EXISTS team_members_user_id_fkey"

    execute "ALTER TABLE team_members ADD CONSTRAINT team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT"
  end
end
