defmodule Tokengate.Repo.Migrations.AddActiveUserIndexToApiKeys do
  @moduledoc """
  Adds a partial index for the "active keys of a user" lookup on `api_keys`.

  `api_keys` only has `api_keys_pkey` and the global unique
  `api_keys_key_hash_index`; listing/looking up a user's active keys
  (`WHERE user_id = $1 AND status = 'active'`) is a sequential scan, and the
  table grows with every user.

  The index is partial on `status = 'active'` because revoked keys are never
  queried by this path — that keeps the index small and skips maintenance for
  the (eventually much larger) revoked set.

  `api_keys` is a regular table, so `CREATE INDEX CONCURRENTLY` would be
  possible in production; it is left plain here for transactional safety
  (the table is small). No unique constraint is added: a user may hold
  several active keys.
  """

  use Ecto.Migration

  @index :api_keys_user_active_idx

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS #{@index}
      ON api_keys (user_id)
      WHERE status = 'active'
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS #{@index}"
  end
end
