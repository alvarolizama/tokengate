defmodule Tokengate.Repo.Migrations.CreateCredentialPools do
  @moduledoc """
  Pools de API keys provider-scoped, montables como lane de un modelo.

  Un pool agrupa credenciales de UN mismo provider y se asigna a un
  `model_provider` como fuente de credenciales, en lugar de una key suelta.
  El provider vive denormalizado en `credential_pool_members.provider_id`
  para poder declarar las dos FKs compuestas que garantizan en la DB que
  pool y credencial son del mismo provider:

    * `(pool_id, provider_id)` → `credential_pools (id, provider_id)`
      ON DELETE CASCADE
    * `(credential_id, provider_id)` → `provider_credentials (id, provider_id)`
      ON DELETE RESTRICT

  Una FK compuesta exige un UNIQUE exacto sobre las columnas referenciadas,
  así que se crean `credential_pools_id_provider_id_unique_index` y
  `provider_credentials_id_provider_id_unique_index` antes de las FKs.

  `model_providers.credential_id` pasa a nullable y entra `pool_id`: un lane
  tiene exactamente UNA fuente, garantizada por el CHECK
  `num_nonnulls(credential_id, pool_id) = 1`. El único índice único nuevo
  para lanes de pool es `(pool_id, model_id)` en scope global; los índices
  por target ya cubren los lanes con pool.

  ## Aviso del `down`

  El `down` BORRA los lanes que apuntan a un pool (no hay a dónde devolverlos:
  `credential_id` vuelve a ser NOT NULL y un pool no es una credencial). Es
  una migración de rollback destructiva para los lanes de pool, no para los
  lanes de una sola key.
  """

  use Ecto.Migration

  def up do
    create table(:credential_pools, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_id, references(:providers, type: :binary_id, on_delete: :restrict),
        null: false

      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Nombre único dentro del provider: un pool es reusable entre modelos del
    # mismo provider, así que dos "principal" en el mismo provider confunden.
    create unique_index(:credential_pools, [:provider_id, :name],
             name: :credential_pools_provider_id_name_unique_index
           )

    # Soporte de la FK compuesta (pool_id, provider_id) de los miembros.
    create unique_index(:credential_pools, [:id, :provider_id],
             name: :credential_pools_id_provider_id_unique_index
           )

    # Soporte de la FK compuesta (credential_id, provider_id) de los miembros.
    create unique_index(:provider_credentials, [:id, :provider_id],
             name: :provider_credentials_id_provider_id_unique_index
           )

    create table(:credential_pool_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Sin `references/2`: la integridad va por las FKs compuestas de abajo,
      # que además fijan el provider de los dos lados.
      add :pool_id, :binary_id, null: false
      add :credential_id, :binary_id, null: false
      add :provider_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    # Una credencial entra una sola vez por pool.
    create unique_index(:credential_pool_members, [:pool_id, :credential_id],
             name: :credential_pool_members_pool_id_credential_id_unique_index
           )

    # Ecto no soporta FKs compuestas de forma nativa: van con `execute/2` y su
    # DROP como reverse. `provider_id` en ambos lados es lo que impide un
    # miembro cross-provider.
    execute(
      """
      ALTER TABLE credential_pool_members
      ADD CONSTRAINT credential_pool_members_pool_id_provider_id_fkey
      FOREIGN KEY (pool_id, provider_id)
      REFERENCES credential_pools (id, provider_id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE credential_pool_members
      DROP CONSTRAINT credential_pool_members_pool_id_provider_id_fkey
      """
    )

    execute(
      """
      ALTER TABLE credential_pool_members
      ADD CONSTRAINT credential_pool_members_credential_id_provider_id_fkey
      FOREIGN KEY (credential_id, provider_id)
      REFERENCES provider_credentials (id, provider_id)
      ON DELETE RESTRICT
      """,
      """
      ALTER TABLE credential_pool_members
      DROP CONSTRAINT credential_pool_members_credential_id_provider_id_fkey
      """
    )

    alter table(:model_providers) do
      add :pool_id, references(:credential_pools, type: :binary_id, on_delete: :restrict),
        null: true

      # El lane pasa a tener UNA fuente: una key suelta o un pool.
      modify :credential_id, :binary_id, null: true
    end

    create constraint(:model_providers, :model_providers_one_source_check,
             check: "num_nonnulls(credential_id, pool_id) = 1"
           )

    # Un pool se monta una sola vez por modelo en scope global. Mismo WHERE
    # que `model_providers_global_credential_unique_index`, pero keyed por
    # pool; los índices por target no distinguen credencial de pool y ya
    # cubren los exclusivos.
    create unique_index(:model_providers, [:pool_id, :model_id],
             where:
               "exclusive_to_group_member_id IS NULL AND exclusive_to_group_id IS NULL AND exclusive_to_service_id IS NULL",
             name: :model_providers_global_pool_unique_index
           )
  end

  def down do
    # DESTRUCTIVO: `credential_id` vuelve a ser NOT NULL y un lane de pool no
    # tiene credencial a la que volver, así que se borran los lanes de pool.
    # Los lanes de una sola key no se tocan.
    execute("DELETE FROM model_providers WHERE pool_id IS NOT NULL")

    drop index(:model_providers, [:pool_id, :model_id],
           name: :model_providers_global_pool_unique_index
         )

    drop constraint(:model_providers, :model_providers_one_source_check)

    alter table(:model_providers) do
      remove :pool_id
      modify :credential_id, :binary_id, null: false
    end

    # Orden inverso: primero los miembros (sus FKs compuestas cuelgan de las
    # dos tablas), luego el pool y al final el UNIQUE que las soporta.
    drop table(:credential_pool_members)
    drop table(:credential_pools)

    drop index(:provider_credentials, [:id, :provider_id],
           name: :provider_credentials_id_provider_id_unique_index
         )
  end
end
