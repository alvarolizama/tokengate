defmodule Tokengate.Repo.Migrations.RemoveSurplusIntelligenceProvider do
  use Ecto.Migration

  @moduledoc """
  Retira `surplus-intelligence` del catálogo de proveedores.

  Surplus Intelligence era un agregador: una sola key compraba acceso a varios
  laboratorios, con pin por fila de `model_providers` (`extra_body["provider"]`)
  para elegir a cuál venderedor rutear, y un header propio
  `x-si-buyer-cost-micro` que reportaba el costo del buyer en micro-USD. Todo
  ese código sale en ESTE MISMO release (`Catalog`, `UsageNormalizer`, router,
  wizard de model-providers), así que la limpieza de datos es lo único que
  falta — y sólo es útil si la fila de código ya no existe: mientras
  `Catalog.@code_providers` conserve la entrada, `CatalogSync.ensure_code_providers/0`
  la re-upserta en el espejo en el siguiente arranque y esta migración no logra
  nada.

  `CatalogSync` sólo upserta — nunca borra — así que quitar la fila de código no
  basta: la fila ya materializada sobrevive en cada instancia. Mismo criterio que
  `RemoveQwenCloudProvider`: el espejo (`catalog_providers`) se limpia primero
  porque es lo que `materialize/0` lee — una fila viva ahí volvería a
  materializar el proveedor en el siguiente arranque; el `providers` sin
  credenciales se borra, y el que está en uso se conserva degradado a `custom`
  con `key = NULL`, para no borrarle la credencial en cascada. Las filas
  degradadas SIGUEN sirviendo y conservan el nombre "Surplus Intelligence" y la
  base URL de SI mientras duren.

  Las llaves de pin de `extra_body` de esos carriles (`provider`, `provider_url`,
  `provider_base_url`) se limpian ANTES de la degradación — mientras
  `providers.key` todavía dice `surplus-intelligence`, que es el match
  confiable. La base URL de SI queda como red de seguridad para una fila ya
  degradada de un intento previo (que tiene `key = NULL`), pero no cubre a un
  operador que haya editado la base URL de su fila; con la key sí. El código que
  interpretaba esas llaves ya no existe y una llave huérfana viaja cruda al
  upstream, que contesta 400. El enlace es vía `credential_id` →
  `provider_credentials.provider_id` porque `model_providers` no tiene columna
  `provider_id`. Sobre filas sin esas llaves el UPDATE es no-op.

  Consecuencia operativa documentada: los carriles degradados dejan de reportar
  costo — la rama de micro-USD se fue con el release — así que el pricing por
  ruta es manual (o $0) y los caps diarios/globales quedan ciegos a ese gasto.
  También pierden el re-formado de reasoning por proveedor pineado: sin pin, los
  knobs `reasoning`/`thinking`/`reasoning_effort` del cliente viajan crudos al
  upstream, y si el seller elegido no acepta esa forma el lane contesta 400.
  Los ids con prefijo de laboratorio en esos carriles dejan de de-prefijarse
  (upstream 404 `no_sellers_for_model`), y los spellings heredados de pin ya no
  se canonicalizan (esta migración los limpia en su lugar).

  El `down` es no-op a propósito — y NO es una reversión: las filas degradadas
  tienen `key = NULL`, así que volver a declarar el proveedor en código inserta
  una fila NUEVA en vez de revivir la vieja (nombre y base URL duplicados, con
  las credenciales varadas en el huérfano). El único camino real de regreso es
  que un operador re-apunte las credenciales a mano.
  """

  def up do
    # El espejo primero: es la entrada de `materialize/0`. Se borra en los DOS
    # casos, también cuando el `providers` sobrevive: esa fila queda con
    # `key = NULL`, así que una fila viva en el espejo insertaría un proveedor
    # DUPLICADO del que se conserva.
    execute("DELETE FROM catalog_providers WHERE key = 'surplus-intelligence'", "")

    # Llaves de pin fuera de `extra_body` — ANTES de degradar, mientras
    # `providers.key` aún matchea. El código que las interpretaba se fue en
    # este mismo release y una llave huérfana viajaría cruda al upstream (400).
    # Enlace por credencial — `model_providers` no tiene `provider_id` — y la
    # base URL de SI como red para una fila previamente degradada. Sobre filas
    # sin esas llaves es no-op.
    execute(
      """
      UPDATE model_providers
      SET extra_body = extra_body - 'provider' - 'provider_url' - 'provider_base_url'
      WHERE credential_id IN (
        SELECT c.id
        FROM provider_credentials c
        JOIN providers p ON p.id = c.provider_id
        WHERE p.key = 'surplus-intelligence'
           OR p.base_url = 'https://api.surplusintelligence.ai/v1'
      )
      """,
      ""
    )

    # Sin credenciales: se borra.
    execute(
      """
      DELETE FROM providers
      WHERE key = 'surplus-intelligence'
        AND source = 'builtin'
        AND NOT EXISTS (
          SELECT 1 FROM provider_credentials c
          WHERE c.provider_id = providers.id
        )
      """,
      ""
    )

    # En uso (un operador ya lo configuró): se conserva y se desprende del
    # catálogo, para no borrarle la credencial en cascada. La fila degradada
    # conserva el nombre y la base URL de SI mientras siga sirviendo.
    execute(
      """
      UPDATE providers
      SET source = 'custom', key = NULL
      WHERE key = 'surplus-intelligence' AND source = 'builtin'
      """,
      ""
    )
  end

  def down do
    # La reversión NO vive aquí: las filas degradadas tienen `key = NULL`, así
    # que redeclarar la fila en `Catalog.@code_providers` insertaría un
    # proveedor NUEVO en vez de revivir el degradado (duplicado de nombre y
    # base URL, credenciales varadas en el huérfano). El único camino real de
    # regreso es que un operador re-apunte las credenciales a mano. `up` no
    # borró ninguna credencial, así que nada que deshacer.
    execute("", "")
  end
end
