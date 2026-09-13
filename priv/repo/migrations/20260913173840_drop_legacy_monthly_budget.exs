defmodule Tokengate.Repo.Migrations.DropLegacyMonthlyBudget do
  use Ecto.Migration

  # Fase B: el "presupuesto mensual" desaparece. El gasto ahora se gobierna por
  # crédito de suscripción (`Tokengate.Credits`), para usuarios y servicios por
  # igual (el servicio usa el default de su grupo). Se quitan las columnas legacy.
  def up do
    alter table(:groups) do
      remove :monthly_budget_per_user_usd
    end

    alter table(:group_members) do
      remove :extra_monthly_budget_usd
    end

    alter table(:services) do
      remove :monthly_budget_usd
    end
  end

  def down do
    alter table(:groups) do
      add :monthly_budget_per_user_usd, :numeric, precision: 12, scale: 2
    end

    alter table(:group_members) do
      add :extra_monthly_budget_usd, :numeric, precision: 12, scale: 2
    end

    alter table(:services) do
      add :monthly_budget_usd, :numeric, precision: 12, scale: 2
    end
  end
end
