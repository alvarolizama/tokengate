defmodule Tokengate.Repo.Migrations.RemoveQwenCloudProvider do
  use Ecto.Migration

  @moduledoc """
  Retira `qwen-cloud` del catálogo de proveedores.

  Qwen Cloud no era una superficie distinta de Alibaba: es la marca y el portal
  de la MISMA infraestructura DashScope internacional. `alibaba` y `qwen-cloud`
  declaraban exactamente lo mismo — base URL `dashscope-intl`, dialecto
  `dashscope`, capacidades llm/embedding/rerank/image/stt/tts/video y rerank en
  `compatible-api/v1/reranks` — y lo único propio era el nombre, el logo y la env
  var `QWEN_API_KEY`. Los ejemplos del propio Qwen usan `DASHSCOPE_API_KEY`
  contra ese mismo host, así que una key de Qwen Cloud entra como credencial de
  `alibaba` sin perder ningún servicio.

  `CatalogSync` sólo upserta — nunca borra — así que quitar la fila de código no
  basta: la fila ya materializada sobrevive en cada instancia. Mismo criterio que
  `RemoveCrofAndNubeFromCatalog`: se borra lo que no tiene credenciales, y lo que
  sí las tiene se conserva degradado a `custom` con `key = NULL`, para que siga
  sirviendo y deje de ser gestionado por el catálogo.

  El espejo (`catalog_providers`) también se limpia, porque es lo que
  `materialize/0` lee: una fila viva ahí volvería a materializar el proveedor en
  el siguiente arranque. Sin esta limpieza quedaría además `active` para siempre
  —el sweep del refresh la marcaría `stale` recién en el próximo refresh
  exitoso, y hasta entonces el mantenimiento no vería el cambio.
  """

  def up do
    # El espejo primero: es la entrada de `materialize/0`. Se borra en los DOS
    # casos, también cuando el `providers` sobrevive: esa fila queda con
    # `key = NULL`, así que una fila viva en el espejo insertaría un proveedor
    # DUPLICADO del que se conserva.
    execute("DELETE FROM catalog_providers WHERE key = 'qwen-cloud'", "")

    # Sin credenciales: se borra.
    execute(
      """
      DELETE FROM providers
      WHERE key = 'qwen-cloud'
        AND source = 'builtin'
        AND NOT EXISTS (
          SELECT 1 FROM provider_credentials c
          WHERE c.provider_id = providers.id
        )
      """,
      ""
    )

    # En uso (un operador ya lo configuró): se conserva y se desprende del
    # catálogo, para no borrarle la credencial en cascada.
    execute(
      """
      UPDATE providers
      SET source = 'custom', key = NULL
      WHERE key = 'qwen-cloud' AND source = 'builtin'
      """,
      ""
    )
  end

  def down do
    # La reversión vive en el CÓDIGO: volver a declarar la fila en
    # `Catalog.@code_providers` (y su customización) hace que el siguiente
    # arranque la upserta en el espejo y la materialice en `providers`. Nada que
    # deshacer aquí: `up` no borró ninguna credencial.
    execute("", "")
  end
end
