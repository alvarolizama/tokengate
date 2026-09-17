defmodule Tokengate.Repo.Migrations.DetachObservabilityDestinationsFromGroups do
  use Ecto.Migration

  @moduledoc """
  Los webhooks de observabilidad dejan de colgar de un grupo (sub mensual).

  Antes cada webhook recibía la telemetría de los miembros de SU grupo. La
  observabilidad es de toda la instalación, así que un webhook ya no tiene
  dueño: recibe la telemetría de todos los sujetos.

  La columna `group_id` se dropea: `observability_destinations` queda como una
  lista global. Se dropea junto con su índice en una sola transacción, así que
  la tabla no tiene que reescribirse por separado.
  """

  def up do
    drop index(:observability_destinations, [:group_id])

    alter table(:observability_destinations) do
      remove :group_id
    end
  end

  def down do
    alter table(:observability_destinations) do
      add :group_id, references(:groups, type: :binary_id), null: true
    end

    create index(:observability_destinations, [:group_id])
  end
end
