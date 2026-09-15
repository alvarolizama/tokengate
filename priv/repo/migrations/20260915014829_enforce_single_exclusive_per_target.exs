defmodule Tokengate.Repo.Migrations.EnforceSingleExclusivePerTarget do
  @moduledoc """
  Un `model_provider` exclusivo es único por (modelo, target): para un mismo
  modelo y un mismo grupo/usuario/servicio solo puede existir **una** fila
  exclusiva.

  Los índices anteriores eran por `credential_id` — permitían N credenciales
  distintas apuntando al mismo target, lo que dejaba filas exclusivas
  ambiguas (mismo scope, misma prioridad, desempate por uuid de credencial).
  Se reemplazan por índices por target.

  El scope global no participa: sigue sin límite.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:model_providers, [:credential_id, :model_id],
                     name: :model_providers_global_credential_unique_index
                   )

    drop_if_exists index(:model_providers, [:credential_id, :model_id, :exclusive_to_group_id],
                     name: :model_providers_group_exclusive_credential_unique_index
                   )

    drop_if_exists index(
                     :model_providers,
                     [:credential_id, :model_id, :exclusive_to_group_member_id],
                     name: :model_providers_member_exclusive_credential_unique_index
                   )

    drop_if_exists index(:model_providers, [:credential_id, :model_id, :exclusive_to_service_id],
                     name: :model_providers_service_exclusive_credential_unique_index
                   )

    # Un solo exclusivo por (modelo, grupo).
    create unique_index(:model_providers, [:model_id, :exclusive_to_group_id],
             where: "exclusive_to_group_id IS NOT NULL",
             name: :model_providers_group_exclusive_target_unique_index
           )

    # Un solo exclusivo por (modelo, miembro).
    create unique_index(:model_providers, [:model_id, :exclusive_to_group_member_id],
             where: "exclusive_to_group_member_id IS NOT NULL",
             name: :model_providers_member_exclusive_target_unique_index
           )

    # Un solo exclusivo por (modelo, servicio).
    create unique_index(:model_providers, [:model_id, :exclusive_to_service_id],
             where: "exclusive_to_service_id IS NOT NULL",
             name: :model_providers_service_exclusive_target_unique_index
           )

    # Global: la misma credencial no puede repetirse dos veces para el mismo
    # modelo en scope global (regla previa, se conserva).
    create unique_index(:model_providers, [:credential_id, :model_id],
             where:
               "exclusive_to_group_member_id IS NULL AND exclusive_to_group_id IS NULL AND exclusive_to_service_id IS NULL",
             name: :model_providers_global_credential_unique_index
           )
  end

  def down do
    drop_if_exists index(:model_providers, [:model_id, :exclusive_to_group_id],
                     name: :model_providers_group_exclusive_target_unique_index
                   )

    drop_if_exists index(:model_providers, [:model_id, :exclusive_to_group_member_id],
                     name: :model_providers_member_exclusive_target_unique_index
                   )

    drop_if_exists index(:model_providers, [:model_id, :exclusive_to_service_id],
                     name: :model_providers_service_exclusive_target_unique_index
                   )

    drop_if_exists index(:model_providers, [:credential_id, :model_id],
                     name: :model_providers_global_credential_unique_index
                   )

    create unique_index(:model_providers, [:credential_id, :model_id],
             where:
               "exclusive_to_group_member_id IS NULL AND exclusive_to_group_id IS NULL AND exclusive_to_service_id IS NULL",
             name: :model_providers_global_credential_unique_index
           )

    create unique_index(:model_providers, [:credential_id, :model_id, :exclusive_to_group_id],
             where: "exclusive_to_group_id IS NOT NULL",
             name: :model_providers_group_exclusive_credential_unique_index
           )

    create unique_index(
             :model_providers,
             [:credential_id, :model_id, :exclusive_to_group_member_id],
             where: "exclusive_to_group_member_id IS NOT NULL",
             name: :model_providers_member_exclusive_credential_unique_index
           )

    create unique_index(:model_providers, [:credential_id, :model_id, :exclusive_to_service_id],
             where: "exclusive_to_service_id IS NOT NULL",
             name: :model_providers_service_exclusive_credential_unique_index
           )
  end
end
