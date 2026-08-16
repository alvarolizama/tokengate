defmodule Tokengate.Repo.Migrations.AddServiceAndSubjectTypeToRequestLogs do
  @moduledoc """
  Makes service requests loggable by adding a proper `service_id` column.

  Services were previously logged with `team_member_id = service.id` (a
  pseudo id that is not a real `team_members` row), which violated the
  `request_logs_team_member_id_fkey` foreign key and caused every service
  request to be silently dropped by the Oban worker.

  This migration:
    * makes `team_member_id` nullable (null for service requests),
    * adds `service_id` (nullable, FK → services, ON DELETE CASCADE),
    * adds `subject_type` ("user" | "service") to distinguish the two.

  The existing FK on `team_member_id` stays in place — FKs allow NULL, so it
  still cascades for user rows and simply passes for service rows.
  """

  use Ecto.Migration

  def up do
    # request_logs is a native Postgres RANGE-partitioned table — raw SQL only.
    execute "ALTER TABLE request_logs ALTER COLUMN team_member_id DROP NOT NULL"

    execute """
    ALTER TABLE request_logs
      ADD COLUMN IF NOT EXISTS service_id uuid
      REFERENCES services(id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE request_logs
      ADD COLUMN IF NOT EXISTS subject_type varchar(255) NOT NULL DEFAULT 'user'
    """

    execute """
    CREATE INDEX IF NOT EXISTS request_logs_service_inserted_idx
      ON request_logs (service_id, inserted_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS request_logs_service_inserted_idx"
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS subject_type"
    execute "ALTER TABLE request_logs DROP COLUMN IF EXISTS service_id"
    execute "ALTER TABLE request_logs ALTER COLUMN team_member_id SET NOT NULL"
  end
end
