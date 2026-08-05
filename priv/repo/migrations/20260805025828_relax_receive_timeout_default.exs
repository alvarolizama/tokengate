defmodule Tokengate.Repo.Migrations.RelaxReceiveTimeoutDefault do
  use Ecto.Migration

  # The old column default (180_000ms) was baked into every credential row,
  # so the new global config default (60s) would never apply. Reset rows that
  # still carry the old default to NULL (meaning "use the config default")
  # and drop the column default so new credentials are born with NULL.
  # Credentials with a custom timeout keep their value untouched.
  #
  # IMPORTANT: We must DROP NOT NULL *before* the UPDATE that sets rows to
  # NULL — otherwise PostgreSQL rejects the UPDATE with a not-null violation.
  def up do
    execute("ALTER TABLE provider_credentials ALTER COLUMN receive_timeout_ms DROP NOT NULL")
    execute("ALTER TABLE provider_credentials ALTER COLUMN receive_timeout_ms DROP DEFAULT")

    execute(
      "UPDATE provider_credentials SET receive_timeout_ms = NULL WHERE receive_timeout_ms = 180000"
    )
  end

  def down do
    execute(
      "UPDATE provider_credentials SET receive_timeout_ms = 180000 WHERE receive_timeout_ms IS NULL"
    )

    execute("ALTER TABLE provider_credentials ALTER COLUMN receive_timeout_ms SET DEFAULT 180000")

    execute("ALTER TABLE provider_credentials ALTER COLUMN receive_timeout_ms SET NOT NULL")
  end
end
