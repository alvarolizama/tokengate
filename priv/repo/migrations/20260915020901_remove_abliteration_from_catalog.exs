defmodule Tokengate.Repo.Migrations.RemoveAbliterationFromCatalog do
  use Ecto.Migration

  @moduledoc """
  Drope abliteration del catálogo builtin de providers.

  CatalogSync solo hace upsert — nunca borra — así que quitar la entrada del
  catálogo compile-time no alcanza: la fila sembrada sobreviviría en cada
  entorno. Este delete borra la fila si no tiene credenciales; si un operador
  sí la está usando, la fila se conserva y pasa a source=custom con key=NULL
  para que siga sirviendo sin gestión del catálogo.

  Down es no-op: CatalogSync re-inserta la fila en el próximo boot.
  """

  def up do
    # Sin credenciales: delete directo.
    execute """
            DELETE FROM providers
            WHERE key = 'abliteration'
              AND source = 'builtin'
              AND NOT EXISTS (
                SELECT 1 FROM provider_credentials c
                WHERE c.provider_id = providers.id
              )
            """,
            ""

    # En uso: se conserva la fila, se desengancha del catálogo.
    execute """
            UPDATE providers
            SET source = 'custom', key = NULL
            WHERE key = 'abliteration' AND source = 'builtin'
            """,
            """
            UPDATE providers
            SET source = 'builtin', key = 'abliteration'
            WHERE name = 'Abliteration' AND source = 'custom'
            """
  end

  def down do
    # CatalogSync re-crea la fila builtin en el próximo boot; nada que hacer.
    execute "", ""
  end
end
