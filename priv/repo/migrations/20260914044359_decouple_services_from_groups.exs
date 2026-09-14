defmodule Tokengate.Repo.Migrations.DecoupleServicesFromGroups do
  @moduledoc """
  Desacopla `services` de `groups`: la sub de crédito pasa a ser directa
  (`services.subscription_id`, un grant por service) y el grupo deja de ser
  obligatorio. Los límites de concurrencia/RPM del service pasan a ser
  absolutos (con defaults 5/60, como los defaults de grupo).

  Backfill: cada service hereda la sub default del grupo al que pertenecía.
  """

  use Ecto.Migration

  def up do
    alter table(:services) do
      add :subscription_id, references(:credit_subscriptions, type: :binary_id,
        on_delete: :nilify_all)
    end

    # Backfill desde el default del grupo; luego el FK deja de ser obligatorio.
    execute """
            UPDATE services s
            SET subscription_id = g.default_subscription_id
            FROM groups g
            WHERE s.group_id = g.id AND g.default_subscription_id IS NOT NULL
            """,
            ""

    alter table(:services) do
      modify :group_id, :binary_id, null: true
    end

    create index(:services, [:subscription_id])
  end

  def down do
    drop index(:services, [:subscription_id])

    # Los services sin grupo vuelven al grupo "Servicios" (como el backfill
    # original de unify_api_keys_and_group_membership).
    execute """
            UPDATE services s
            SET group_id = (SELECT id FROM groups WHERE name = 'Servicios' LIMIT 1)
            WHERE group_id IS NULL
            """,
            ""

    execute """
            UPDATE services s
            SET group_id = (SELECT g.id FROM groups g
                            WHERE g.default_subscription_id = s.subscription_id
                            LIMIT 1)
            WHERE s.subscription_id IS NOT NULL AND s.group_id IS NULL
            """,
            ""

    alter table(:services) do
      modify :group_id, :binary_id, null: false
      remove :subscription_id
    end
  end
end
