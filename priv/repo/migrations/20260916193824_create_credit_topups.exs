defmodule Tokengate.Repo.Migrations.CreateCreditTopups do
  use Ecto.Migration

  def up do
    # Crédito extra de un solo uso, por usuario o servicio, con expiración
    # opcional contada desde su creación. Reemplaza a los top-ups que hoy
    # viven como `credit_subscriptions` (`recurrence = "none"`).
    create table(:credit_topups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Un top-up tiene exactamente un dueño: user_id o service_id
      # (uno y solo uno, forzado por el check de abajo).
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all)

      # El monto vive en USD, la misma unidad que request_logs.provider_cost_usd.
      add :amount_usd, :decimal, precision: 12, scale: 6, null: false
      add :status, :string, null: false, default: "active"
      add :expires_in_days, :integer
      add :expires_at, :utc_datetime

      add :label, :string
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    # Exactamente un dueño: suma booleana de ambos FKs debe dar 1.
    create constraint(:credit_topups, :credit_topups_exactly_one_subject,
             check: "(user_id IS NOT NULL)::int + (service_id IS NOT NULL)::int = 1"
           )

    create index(:credit_topups, [:user_id])
    create index(:credit_topups, [:service_id])
    create index(:credit_topups, [:expires_at])
  end

  def down do
    drop table(:credit_topups)
  end
end
