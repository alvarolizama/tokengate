defmodule Tokengate.Repo.Migrations.CanonicalizeAggregatorProviderPins do
  use Ecto.Migration

  @moduledoc """
  Corrige los spellings de pin que el menú del operador ofrecía y el
  marketplace NO resuelve.

  `provider` es una allow-list en Surplus: un valor que no resuelve no "rutea
  igual", deja la petición SIN ofertas (404 `no_sellers_for_model`) o contesta
  400 `unsupported_provider` — incluso cuando el modelo pedido sí tiene ofertas
  activas. Los valores afectados salieron de la tabla interna de spellings
  (`Catalog`), no del marketplace:

    * `api.openrouter.ai` — host que no existe (no resuelve en DNS; el host real
      de la API es `openrouter.ai`).
    * `https://api.openrouter.ai/api/v1` — el mismo host muerto, en forma URL.
    * `fireworks-ai` — la clave de models.dev, no un id del marketplace
      (el suyo es `fireworks`): 400 `unsupported_provider`.
    * `venice.ai` — 400 `unsupported_provider` (acepta `venice`).

  `Catalog.canonicalize_aggregator_pins/2` ya los corrige al serializar el body,
  así que ninguna fila queda rota aunque la migración no haya corrido; esto
  además deja el valor GUARDADO a la par de lo que se manda, que es lo que pinta
  el badge de pin y el select del formulario (un valor fuera de las opciones del
  menú deja el select sin selección visible).

  El `extra_body` es libre y el campo solo existe en filas de agregador, pero el
  UPDATE no filtra por proveedor: esos cuatro spellings solo pudieron salir de
  nuestro propio menú, así que cualquier fila que los tenga está mal.

  Irreversible a propósito: volver a poner el spelling roto no "deshace" nada.
  """

  @pins [
    {"api.openrouter.ai", "openrouter"},
    {"https://api.openrouter.ai/api/v1", "openrouter"},
    {"fireworks-ai", "fireworks"},
    {"venice.ai", "venice"}
  ]

  def change do
    for {from, to} <- @pins do
      execute(
        """
        UPDATE model_providers
        SET extra_body = jsonb_set(extra_body, '{provider}', to_jsonb('#{to}'::text))
        WHERE extra_body ->> 'provider' = '#{from}'
        """,
        ""
      )
    end
  end
end
