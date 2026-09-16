defmodule Tokengate.Repo.Migrations.SpendLimitsAndUnlimited do
  use Ecto.Migration

  # Límite mensual de gasto por sujeto (group/user/service) más conc/RPM
  # propios del usuario: permite migrar el crédito por suscripción a límites
  # por sujeto.
  #
  # Decisiones (ya tomadas):
  # - `monthly_spend_limit_usd`: numeric(12,2), nullable y SIN default.
  #   NULL = sin límite propio definido; `0` = CERO (jamás ilimitado).
  # - `unlimited_spend`: boolean not null default false. Es el ÚNICO camino a
  #   ilimitado, explícito y auditable.
  # - `users.default_concurrency_limit` / `users.default_rpm_limit`: conc/RPM
  #   propios del usuario (null = sin propios); services y groups ya tienen
  #   los suyos y no se tocan aquí.
  def up do
    alter table(:groups) do
      add :monthly_spend_limit_usd, :decimal, precision: 12, scale: 2
      add :unlimited_spend, :boolean, null: false, default: false
    end

    alter table(:users) do
      add :monthly_spend_limit_usd, :decimal, precision: 12, scale: 2
      add :unlimited_spend, :boolean, null: false, default: false
      add :default_concurrency_limit, :integer
      add :default_rpm_limit, :integer
    end

    alter table(:services) do
      add :monthly_spend_limit_usd, :decimal, precision: 12, scale: 2
      add :unlimited_spend, :boolean, null: false, default: false
    end
  end

  def down do
    # Orden inverso al `up`: services, users, groups.
    alter table(:services) do
      remove :unlimited_spend
      remove :monthly_spend_limit_usd
    end

    alter table(:users) do
      remove :default_rpm_limit
      remove :default_concurrency_limit
      remove :unlimited_spend
      remove :monthly_spend_limit_usd
    end

    alter table(:groups) do
      remove :unlimited_spend
      remove :monthly_spend_limit_usd
    end
  end
end
