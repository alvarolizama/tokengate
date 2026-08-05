defmodule Tokengate.Repo.Migrations.RelaxReceiveTimeoutDefault do
  use Ecto.Migration

  # The old column default (180_000ms) was baked into every credential row,
  # so the new global config default (60s) would never apply. Reset rows that
  # still carry the old default to NULL (meaning "use the config default")
  # and drop the column default so new credentials are born with NULL.
  # Credentials with a custom timeout keep their value untouched.
  def up do
    execute(
      "UPDATE provider_credentials SET receive_timeout_ms = NULL WHERE receive_timeout_ms = 180000"
    )

    alter table(:provider_credentials) do
      modify(:receive_timeout_ms, :integer,
        null: true,
        default: nil,
        from: {:integer, null: true, default: 180_000}
      )
    end
  end

  def down do
    alter table(:provider_credentials) do
      modify(:receive_timeout_ms, :integer,
        null: true,
        default: 180_000,
        from: {:integer, null: true, default: nil}
      )
    end

    execute(
      "UPDATE provider_credentials SET receive_timeout_ms = 180000 WHERE receive_timeout_ms IS NULL"
    )
  end
end
