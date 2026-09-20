defmodule Tokengate.Repo.Migrations.DropModelCatalogMirror do
  use Ecto.Migration

  @moduledoc """
  Retira el espejo de MODELOS de models.dev.

  El gateway mantiene el espejo a nivel PROVEEDOR (`catalog_providers`) y el de
  labs (`labs`), que alimentan el alta de proveedor y las marcas; el nivel
  MODELO sólo servía a cuatro lectores de admin (badge "ya existe", acotado de
  proveedores del modal de lane, prellenado de `provider_model` y de precio de
  lista) y ninguna ruta de request lo consultaba: el router usa
  `Catalog.bare_model_ids?` y `ModelCatalog.short_name/1` (función pura sobre el
  string del lane) y la facturación lee el coste reportado por el upstream con
  caída al precio manual de `model_providers`.

  A cambio, el alta lista los modelos del proveedor EN VIVO con su API key
  (`/v1/models`, y el catálogo por servicio donde el proveedor lo publica).

  Se van con las dos tablas:

    * `models.catalog_model_key` — el vínculo que sólo sostenía el badge;
    * las seis columnas `models_*` / `offers_*` de `catalog_sync_state`, que
      contaban la mitad retirada del refresh.

  El `providers.json` y el `labs.json` vendorizados NO se tocan: son las otras
  dos mitades del mismo refresh.
  """

  def up do
    drop table(:catalog_model_offers)
    drop table(:catalog_models)

    alter table(:models) do
      remove :catalog_model_key
    end

    alter table(:catalog_sync_state) do
      remove :models_inserted
      remove :models_updated
      remove :models_stale
      remove :offers_inserted
      remove :offers_updated
      remove :offers_stale
    end
  end

  # Irreversible a propósito: recrear las tablas vacías no devuelve el espejo
  # (lo llenaba un snapshot que ya no viaja en el release), y devolver
  # `catalog_model_key` sin sus claves no restaura ningún vínculo real.
  def down do
    raise "drop_model_catalog_mirror es irreversible: el espejo se alimentaba de un snapshot que ya no existe"
  end
end
