defmodule Tokengate.Repo.Migrations.AddCreditSubscriptions do
  use Ecto.Migration

  # Fase A del modelo de crédito: introduce las suscripciones que otorgan
  # crédito (unidades gastables), sin borrar todavía el presupuesto mensual
  # legado de grupos/servicios (los servicios migran en Fase B).
  #
  # - `credit_subscriptions` — la *policy*: monto de crédito, recurrencia,
  #   día de corte, rollover. `user_id` NULL ⇒ es el default de uno o varios
  #   grupos; `user_id` seteado ⇒ es una sub directa del usuario.
  # - `groups.default_subscription_id` — un grupo tiene UNA sub default; varios
  #   grupos pueden apuntar a la MISMA sub (se comparte, no se duplica).
  # - `request_logs.credit_subscription_id` — de qué sub se debitó cada request
  #   (el grant es `(subscription_id, user_id)`; se necesita registrar la sub
  #   porque el fallback a crédito directo depende del saldo en runtime).
  def up do
    create table(:credit_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Dueño directo. NULL ⇒ sub de grupo (referenciada por groups).
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      add :name, :string

      # Crédito otorgado por ciclo (unidades).
      add :units, :bigint, null: false, default: 0

      # "none" (top-up de una sola vez, no se renueva) | "monthly"
      add :recurrence, :string, null: false, default: "monthly"
      # 1..31 — día de corte del ciclo (solo aplica cuando recurrence = "monthly")
      add :reset_day, :integer

      # "reset" (el remanente se pierde) | "rollover" (se arrastra un %)
      add :rollover_mode, :string, null: false, default: "reset"
      add :rollover_pct, :integer
      add :rollover_cap_units, :bigint

      add :status, :string, null: false, default: "active"
      add :starts_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:credit_subscriptions, [:user_id])
    create index(:credit_subscriptions, [:status])

    alter table(:groups) do
      add :default_subscription_id,
          references(:credit_subscriptions, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:request_logs) do
      add :credit_subscription_id, :binary_id
    end
  end

  def down do
    alter table(:request_logs) do
      remove :credit_subscription_id
    end

    alter table(:groups) do
      remove :default_subscription_id
    end

    drop table(:credit_subscriptions)
  end
end
