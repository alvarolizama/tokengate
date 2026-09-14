defmodule Tokengate.Repo.Migrations.DecoupleServicesFromGroups do
  @moduledoc """
  Desacopla `services` de `groups`: la sub de crédito pasa a ser directa
  (`services.subscription_id`, un grant por service) y el grupo deja de ser
  obligatorio. Los límites de concurrencia/RPM del service pasan a ser
  absolutos (nil → default 5/60).

  Backfill: cada service hereda la sub default del grupo al que pertenecía,
  y sus extras de límite se suman al default del grupo para preservar el
  límite efectivo pre-migración.
  """

  use Ecto.Migration

  def up do
    alter table(:services) do
      add :subscription_id,
          references(:credit_subscriptions,
            type: :binary_id,
            on_delete: :nilify_all
          )
    end

    # Backfill desde el default del grupo.
    execute """
            UPDATE services s
            SET subscription_id = g.default_subscription_id
            FROM groups g
            WHERE s.group_id = g.id AND g.default_subscription_id IS NOT NULL
            """,
            ""

    # Preservar límites efectivos: los valores previos eran extras aditivos
    # sobre el default del grupo; ahora son absolutos.
    execute """
            UPDATE services s
            SET concurrency_limit = s.concurrency_limit + g.default_concurrency_limit,
                rpm_limit = s.rpm_limit + g.default_rpm_limit
            FROM groups g
            WHERE s.group_id = g.id
            """,
            ""

    alter table(:services) do
      modify :group_id, :binary_id, null: true
      modify :concurrency_limit, :integer, null: true
      modify :rpm_limit, :integer, null: true
    end

    create index(:services, [:subscription_id])
  end

  def down do
    drop index(:services, [:subscription_id])

    # Rebasar los límites de vuelta a extras (default del grupo) donde se pueda.
    execute """
            UPDATE services s
            SET concurrency_limit = GREATEST(s.concurrency_limit - g.default_concurrency_limit, 1),
                rpm_limit = GREATEST(s.rpm_limit - g.default_rpm_limit, 1)
            FROM groups g
            WHERE s.group_id = g.id
            """,
            ""

    # Los services sin grupo vuelven al grupo "Servicios" (como el backfill
    # original de unify_api_keys_and_group_membership), preferentemente a un
    # grupo cuyo default sea la sub del service.
    execute """
            UPDATE services s
            SET group_id = (SELECT g.id FROM groups g
                            WHERE g.default_subscription_id = s.subscription_id
                            LIMIT 1)
            WHERE group_id IS NULL
            """,
            ""

    execute """
            UPDATE services s
            SET group_id = (SELECT id FROM groups WHERE name = 'Servicios' LIMIT 1)
            WHERE group_id IS NULL
            """,
            ""

    alter table(:services) do
      modify :concurrency_limit, :integer, null: false, default: 5
      modify :rpm_limit, :integer, null: false, default: 60
      modify :group_id, :binary_id, null: false
      remove :subscription_id
    end
  end
end
