defmodule Tokengate.Repo.Migrations.RemoveCrofAndNubeFromCatalog do
  use Ecto.Migration

  @moduledoc """
  Drops crof_ai and nube from the builtin provider catalog.

  CatalogSync only upserts — it never deletes — so removing the entries
  from the compile-time catalog is not enough: the seeded rows would
  survive forever in every environment. This deletes the rows that have
  no credentials attached. Rows WITH credentials (an operator actually
  using them) are preserved and their `source` flipped to "custom" so
  they keep working and stop being catalog-managed.

  Down re-inserts the catalog rows (CatalogSync would too on next boot).
  """

  def up do
    # Unused builtins: straight delete.
    execute """
            DELETE FROM providers
            WHERE key IN ('crof_ai', 'nube')
              AND source = 'builtin'
              AND NOT EXISTS (
                SELECT 1 FROM provider_credentials c
                WHERE c.provider_id = providers.id
              )
            """,
            ""

    # In use: keep the row, detach from the catalog.
    execute """
            UPDATE providers
            SET source = 'custom', key = NULL
            WHERE key IN ('crof_ai', 'nube') AND source = 'builtin'
            """,
            """
            UPDATE providers
            SET source = 'builtin', key = 'crof_ai'
            WHERE name = 'CrofAi' AND source = 'custom'
            """
  end

  def down do
    # CatalogSync re-creates the builtin rows on next boot; nothing to do.
    execute "", ""
  end
end
